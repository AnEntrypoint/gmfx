const std = @import("std");
const command_specs = @import("command_specs.zig");

const SlashKind = command_specs.SlashKind;
const SlashRegistry = command_specs.SlashRegistry;

pub const ParsedCommand = union(enum) {
    quit,
    new_session,
    launch_instance: []const u8,
    close_instance,
    show_agents,
    reset_session,
    resume_session,
    rename_session: []const u8,
    fork_session,
    help,
    login,
    logout: []const u8,
    provider,
    status,
    image: []const u8,
    images: []const u8,
    model: []const u8,
    effort: []const u8,
    permissions: []const u8,
    auto_mode,
    yolo_mode,
    allowlist: []const u8,
    stats,
    usage,
    undo,
    mcp: []const u8,
    skills: []const u8,
    plugins: []const u8,
    copy,
    feedback,
    trace,
    compact: []const u8,
    export_md: []const u8,
    settings: []const u8,
    credits,
    paste,
    fast: []const u8,
    ultrafast: []const u8,
    statusline: []const u8,
    notifications: []const u8,
    workspace: []const u8,
    shell: []const u8,
    version,
    parity: []const u8,
    tower: TowerAction,
    export_debug_zip,
    import_sessions,
    tasks: []const u8,
    experiments: []const u8,
    theme: []const u8,
    plan: []const u8,
    mcp_config: []const u8,
    swarm: []const u8,
    withdraw_prompts: []const u8,
    fork_argument: []const u8,
    provider_argument: []const u8,
    secondary_model: []const u8,
    editor: []const u8,
    reload,
    reload_tui,
    side_question: []const u8,
    new_session_named: []const u8,
    extension: Extension,
    unknown,
};

pub const Extension = struct {
    kind: SlashKind,
    rest: []const u8,
};

pub const TowerAction = union(enum) { status, enter, exit, teardown, base: []const u8 };

pub const PermissionPickerStart = enum { auto, yolo, current };

pub fn towerAction(payload: []const u8) TowerAction {
    const word = std.mem.trim(u8, payload, " \t");
    if (word.len == 0 or std.ascii.eqlIgnoreCase(word, "status")) return .status;
    if (std.ascii.eqlIgnoreCase(word, "on")) return .enter;
    if (std.ascii.eqlIgnoreCase(word, "off")) return .exit;
    if (std.ascii.eqlIgnoreCase(word, "teardown")) return .teardown;
    return .{ .base = word };
}

pub const kimi_permission_command = "/permission";

fn typedKimiPermissionCommand(registry: SlashRegistry, cmd: []const u8) bool {
    const prefix = command_specs.matchedSlashPrefix(registry, cmd, .permissions) orelse return false;
    return std.mem.eql(u8, prefix, kimi_permission_command);
}

pub const CommandHandlers = struct {
    ctx: *anyopaque,
    quit: *const fn (ctx: *anyopaque) anyerror!void,
    new_session: *const fn (ctx: *anyopaque) anyerror!void,
    launch_instance: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    close_instance: *const fn (ctx: *anyopaque) anyerror!void,
    show_agents: *const fn (ctx: *anyopaque) anyerror!void,
    reset_session: *const fn (ctx: *anyopaque) anyerror!void,
    resume_session: *const fn (ctx: *anyopaque) anyerror!void,
    fork_session: *const fn (ctx: *anyopaque) anyerror!void,
    show_help: *const fn (ctx: *anyopaque) anyerror!void,
    login: *const fn (ctx: *anyopaque) anyerror!void,
    logout: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    provider: *const fn (ctx: *anyopaque) anyerror!void,
    setup_alias: *const fn (ctx: *anyopaque) anyerror!void,
    show_status: *const fn (ctx: *anyopaque) anyerror!void,
    attach_image: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
    manage_images: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_model: *const fn (ctx: *anyopaque, query: []const u8) anyerror!void,
    handle_effort: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_permissions: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_allowlist: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    show_stats: *const fn (ctx: *anyopaque) anyerror!void,
    show_usage: *const fn (ctx: *anyopaque) anyerror!void,
    undo_last: *const fn (ctx: *anyopaque) anyerror!void,
    handle_mcp: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_skills: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_plugins: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    copy_last: *const fn (ctx: *anyopaque) anyerror!void,
    submit_feedback: *const fn (ctx: *anyopaque) anyerror!void,
    create_trace: *const fn (ctx: *anyopaque) anyerror!void,
    compact_history: *const fn (ctx: *anyopaque, instruction: []const u8) anyerror!void,
    export_md: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
    handle_settings: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    show_credits: *const fn (ctx: *anyopaque) anyerror!void,
    paste_clipboard: *const fn (ctx: *anyopaque) anyerror!void,
    handle_fast: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_ultrafast: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_statusline: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    rename_session: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_notifications: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_workspace: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_shell: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_parity: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_tower: ?*const fn (ctx: *anyopaque, action: TowerAction) anyerror!void = null,
    handle_rewind: ?*const fn (ctx: *anyopaque, rest: []const u8) anyerror!void = null,
    pick_permission_mode: ?*const fn (ctx: *anyopaque, start: PermissionPickerStart) anyerror!void = null,
    export_debug_zip: *const fn (ctx: *anyopaque) anyerror!void,
    import_sessions: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    show_tasks: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    show_experiments: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_theme: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_plan: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_mcp_config: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_swarm: ?*const fn (ctx: *anyopaque, rest: []const u8) anyerror!void = null,
    withdraw_prompts: ?*const fn (ctx: *anyopaque, rest: []const u8) anyerror!void = null,
    fork_argument: ?*const fn (ctx: *anyopaque, rest: []const u8) anyerror!void = null,
    provider_argument: ?*const fn (ctx: *anyopaque, rest: []const u8) anyerror!void = null,
    handle_secondary_model: ?*const fn (ctx: *anyopaque, rest: []const u8) anyerror!void = null,
    handle_editor: ?*const fn (ctx: *anyopaque, rest: []const u8) anyerror!void = null,
    reload: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    reload_tui: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    ask_side_question: ?*const fn (ctx: *anyopaque, rest: []const u8) anyerror!void = null,
    new_session_named: ?*const fn (ctx: *anyopaque, rest: []const u8) anyerror!void = null,
    handle_extension: ?*const fn (ctx: *anyopaque, kind: SlashKind, rest: []const u8) anyerror!void = null,
    show_version: *const fn (ctx: *anyopaque) anyerror!void,
    unknown: *const fn (ctx: *anyopaque, cmd: []const u8) anyerror!void,
};

fn command_payload(cmd: []const u8, prefix: []const u8) []const u8 {
    return std.mem.trim(u8, cmd[prefix.len..], " \t");
}

fn parsedCommand(kind: SlashKind, payload: []const u8) ParsedCommand {
    return switch (kind) {
        .quit => .quit,
        .new_session => if (payload.len == 0) .new_session else .{ .new_session_named = payload },
        .launch_instance => .{ .launch_instance = payload },
        .close_instance => .close_instance,
        .show_agents => .show_agents,
        .reset_session => .reset_session,
        .resume_session => if (payload.len == 0) .resume_session else extension(kind, payload),
        .rename_session => .{ .rename_session = payload },
        .fork_session => if (payload.len == 0) .fork_session else .{ .fork_argument = payload },
        .help => .help,
        .login => .login,
        .logout => .{ .logout = payload },
        .provider => if (payload.len == 0) .provider else .{ .provider_argument = payload },
        .status => .status,
        .images => .{ .images = payload },
        .image => .{ .image = payload },
        .model => .{ .model = payload },
        .effort => .{ .effort = payload },
        .permissions => .{ .permissions = payload },
        .auto_mode => .auto_mode,
        .yolo_mode => .yolo_mode,
        .allowlist => .{ .allowlist = payload },
        .stats => .stats,
        .usage => .usage,
        .undo => if (payload.len == 0) .undo else .{ .withdraw_prompts = payload },
        .mcp => .{ .mcp = payload },
        .skills => .{ .skills = payload },
        .plugins => .{ .plugins = payload },
        .copy => if (payload.len == 0) .copy else extension(kind, payload),
        .feedback => .feedback,
        .trace => .trace,
        .compact => .{ .compact = payload },
        .export_md => .{ .export_md = payload },
        .settings => .{ .settings = payload },
        .credits => .credits,
        .paste => .paste,
        .fast => .{ .fast = payload },
        .ultrafast => .{ .ultrafast = payload },
        .statusline => .{ .statusline = payload },
        .notifications => .{ .notifications = payload },
        .workspace => .{ .workspace = payload },
        .shell => .{ .shell = payload },
        .version => .version,
        .parity => .{ .parity = payload },
        .tower => .{ .tower = towerAction(payload) },
        .export_debug_zip => .export_debug_zip,
        .import_sessions => .import_sessions,
        .tasks => .{ .tasks = payload },
        .experiments => .{ .experiments = payload },
        .theme => .{ .theme = payload },
        .plan => .{ .plan = payload },
        .mcp_config => .{ .mcp_config = payload },
        .swarm => .{ .swarm = payload },
        .secondary_model => .{ .secondary_model = payload },
        .editor => .{ .editor = payload },
        .reload => .reload,
        .reload_tui => .reload_tui,
        .side_question => .{ .side_question = payload },
        .rewind, .init, .diff, .memory, .hooks, .doctor, .loop, .branch, .context, .autocompact, .keybindings, .output_style => extension(kind, payload),
    };
}

fn extension(kind: SlashKind, payload: []const u8) ParsedCommand {
    return .{ .extension = .{ .kind = kind, .rest = payload } };
}

pub fn parse(registry: SlashRegistry, cmd: []const u8) ParsedCommand {
    for (registry.commands) |spec| {
        if (spec.accepts_payload) {
            if (command_specs.matchedSlashPrefix(registry, cmd, spec.kind)) |prefix| {
                return parsedCommand(spec.kind, command_payload(cmd, prefix));
            }
        } else if (command_specs.matchesSlashExact(registry, cmd, spec.kind)) {
            return parsedCommand(spec.kind, "");
        }
    }
    return .unknown;
}

pub const deprecated_setup_alias = "/setup";

fn typedSetupAlias(registry: SlashRegistry, cmd: []const u8) bool {
    const matched = registry.matchExact(cmd) orelse return false;
    return std.mem.eql(u8, matched.token, deprecated_setup_alias);
}

pub fn route(registry: SlashRegistry, handlers: *const CommandHandlers, cmd: []const u8) !void {
    switch (parse(registry, cmd)) {
        .quit => try handlers.quit(handlers.ctx),
        .new_session => try handlers.new_session(handlers.ctx),
        .launch_instance => |rest| try handlers.launch_instance(handlers.ctx, rest),
        .close_instance => try handlers.close_instance(handlers.ctx),
        .show_agents => try handlers.show_agents(handlers.ctx),
        .reset_session => try handlers.reset_session(handlers.ctx),
        .resume_session => try handlers.resume_session(handlers.ctx),
        .rename_session => |rest| try handlers.rename_session(handlers.ctx, rest),
        .fork_session => try handlers.fork_session(handlers.ctx),
        .help => try handlers.show_help(handlers.ctx),
        .login => try handlers.login(handlers.ctx),
        .logout => |rest| try handlers.logout(handlers.ctx, rest),
        .provider => if (typedSetupAlias(registry, cmd))
            try handlers.setup_alias(handlers.ctx)
        else
            try handlers.provider(handlers.ctx),
        .status => try handlers.show_status(handlers.ctx),
        .image => |path| try handlers.attach_image(handlers.ctx, path),
        .images => |rest| try handlers.manage_images(handlers.ctx, rest),
        .model => |query| try handlers.handle_model(handlers.ctx, query),
        .effort => |rest| try handlers.handle_effort(handlers.ctx, rest),
        .permissions => |rest| if (rest.len == 0 and handlers.pick_permission_mode != null and typedKimiPermissionCommand(registry, cmd))
            try handlers.pick_permission_mode.?(handlers.ctx, .current)
        else
            try handlers.handle_permissions(handlers.ctx, rest),
        .auto_mode => if (handlers.pick_permission_mode) |pick|
            try pick(handlers.ctx, .auto)
        else
            try handlers.handle_permissions(handlers.ctx, "auto"),
        .yolo_mode => if (handlers.pick_permission_mode) |pick|
            try pick(handlers.ctx, .yolo)
        else
            try handlers.handle_permissions(handlers.ctx, "yolo"),
        .allowlist => |rest| try handlers.handle_allowlist(handlers.ctx, rest),
        .stats => try handlers.show_stats(handlers.ctx),
        .usage => try handlers.show_usage(handlers.ctx),
        .undo => try handlers.undo_last(handlers.ctx),
        .mcp => |rest| try handlers.handle_mcp(handlers.ctx, rest),
        .skills => |rest| try handlers.handle_skills(handlers.ctx, rest),
        .plugins => |rest| try handlers.handle_plugins(handlers.ctx, rest),
        .copy => try handlers.copy_last(handlers.ctx),
        .feedback => try handlers.submit_feedback(handlers.ctx),
        .trace => try handlers.create_trace(handlers.ctx),
        .compact => |instruction| try handlers.compact_history(handlers.ctx, instruction),
        .export_md => |path| try handlers.export_md(handlers.ctx, path),
        .settings => |rest| try handlers.handle_settings(handlers.ctx, rest),
        .credits => try handlers.show_credits(handlers.ctx),
        .paste => try handlers.paste_clipboard(handlers.ctx),
        .fast => |rest| try handlers.handle_fast(handlers.ctx, rest),
        .ultrafast => |rest| try handlers.handle_ultrafast(handlers.ctx, rest),
        .statusline => |rest| try handlers.handle_statusline(handlers.ctx, rest),
        .notifications => |rest| try handlers.handle_notifications(handlers.ctx, rest),
        .workspace => |rest| try handlers.handle_workspace(handlers.ctx, rest),
        .shell => |rest| try handlers.handle_shell(handlers.ctx, rest),
        .version => try handlers.show_version(handlers.ctx),
        .parity => |rest| try handlers.handle_parity(handlers.ctx, rest),
        .tower => |action| if (handlers.handle_tower) |handle|
            try handle(handlers.ctx, action)
        else
            try handlers.unknown(handlers.ctx, cmd),
        .export_debug_zip => try handlers.export_debug_zip(handlers.ctx),
        .import_sessions => if (handlers.import_sessions) |import_sessions|
            try import_sessions(handlers.ctx)
        else
            try handlers.unknown(handlers.ctx, cmd),
        .tasks => |rest| try handlers.show_tasks(handlers.ctx, rest),
        .experiments => |rest| try handlers.show_experiments(handlers.ctx, rest),
        .theme => |rest| try handlers.handle_theme(handlers.ctx, rest),
        .plan => |rest| try handlers.handle_plan(handlers.ctx, rest),
        .mcp_config => |rest| try handlers.handle_mcp_config(handlers.ctx, rest),
        .swarm => |rest| if (handlers.handle_swarm) |handle|
            try handle(handlers.ctx, rest)
        else
            try handlers.unknown(handlers.ctx, cmd),
        .withdraw_prompts => |rest| if (handlers.withdraw_prompts) |withdraw|
            try withdraw(handlers.ctx, rest)
        else
            try handlers.unknown(handlers.ctx, cmd),
        .fork_argument => |rest| if (handlers.fork_argument) |fork_with|
            try fork_with(handlers.ctx, rest)
        else
            try handlers.unknown(handlers.ctx, cmd),
        .provider_argument => |rest| if (handlers.provider_argument) |provider_with|
            try provider_with(handlers.ctx, rest)
        else
            try handlers.unknown(handlers.ctx, cmd),
        .secondary_model => |rest| if (handlers.handle_secondary_model) |handle|
            try handle(handlers.ctx, rest)
        else
            try handlers.unknown(handlers.ctx, cmd),
        .editor => |rest| if (handlers.handle_editor) |handle|
            try handle(handlers.ctx, rest)
        else
            try handlers.unknown(handlers.ctx, cmd),
        .reload => if (handlers.reload) |reload|
            try reload(handlers.ctx)
        else
            try handlers.unknown(handlers.ctx, cmd),
        .reload_tui => if (handlers.reload_tui) |reload_tui|
            try reload_tui(handlers.ctx)
        else
            try handlers.unknown(handlers.ctx, cmd),
        .side_question => |rest| if (handlers.ask_side_question) |ask|
            try ask(handlers.ctx, rest)
        else
            try handlers.unknown(handlers.ctx, cmd),
        .new_session_named => |rest| if (handlers.new_session_named) |start_named|
            try start_named(handlers.ctx, rest)
        else
            try handlers.unknown(handlers.ctx, cmd),
        .extension => |requested| if (requested.kind == .rewind and handlers.handle_rewind != null)
            try handlers.handle_rewind.?(handlers.ctx, requested.rest)
        else if (handlers.handle_extension) |handle|
            try handle(handlers.ctx, requested.kind, requested.rest)
        else
            try handlers.unknown(handlers.ctx, cmd),
        .unknown => try handlers.unknown(handlers.ctx, cmd),
    }
}

fn testSlashRegistry() SlashRegistry {
    const builtin_commands = @import("../../builtins/commands.zig");
    return builtin_commands.slash_registry;
}

test "parse extracts model command payload" {
    const parsed = parse(testSlashRegistry(), "/model claude-opus");
    switch (parsed) {
        .model => |query| try std.testing.expectEqualStrings("claude-opus", query),
        else => return error.TestExpectedEqual,
    }
}

test "parse extracts an optional logout provider" {
    switch (parse(testSlashRegistry(), "/logout chatgpt")) {
        .logout => |provider| try std.testing.expectEqualStrings("chatgpt", provider),
        else => return error.TestExpectedLogoutCommand,
    }
}

test "parse rejects removed plural model command" {
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/models"));
}

test "parse maps /tower on to enter and /tower off to exit" {
    switch (parse(testSlashRegistry(), "/tower on")) {
        .tower => |action| try std.testing.expect(action == .enter),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/tower off")) {
        .tower => |action| try std.testing.expect(action == .exit),
        else => return error.TestExpectedEqual,
    }
}

test "parse maps /tower alone and /tower status to status, teardown to teardown, and any other word to a base branch" {
    switch (parse(testSlashRegistry(), "/tower")) {
        .tower => |action| try std.testing.expect(action == .status),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/tower status")) {
        .tower => |action| try std.testing.expect(action == .status),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/tower teardown")) {
        .tower => |action| try std.testing.expect(action == .teardown),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/tower release/1.2")) {
        .tower => |action| switch (action) {
            .base => |base| try std.testing.expectEqualStrings("release/1.2", base),
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "/permission alone opens the permission picker on the mode in use, and /permissions alone still reaches the permissions handler" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.pick_permission_mode = recordPermissionPicker;
    handlers.handle_permissions = recordPermissions;

    try route(testSlashRegistry(), &handlers, "/permission");
    try std.testing.expectEqualStrings("permission_picker", ctx.called);
    try std.testing.expectEqualStrings("current", ctx.payload);

    try route(testSlashRegistry(), &handlers, "/permissions");
    try std.testing.expectEqualStrings("permissions", ctx.called);

    try route(testSlashRegistry(), &handlers, "/permission auto");
    try std.testing.expectEqualStrings("permissions", ctx.called);
    try std.testing.expectEqualStrings("auto", ctx.payload);
}

fn recordPermissionPicker(ctx: *anyopaque, start: PermissionPickerStart) anyerror!void {
    testContext(ctx).called = "permission_picker";
    testContext(ctx).payload = @tagName(start);
}

fn recordPermissions(ctx: *anyopaque, rest: []const u8) anyerror!void {
    testContext(ctx).called = "permissions";
    testContext(ctx).payload = rest;
}

test "route opens the permission picker for /auto, /yolo and /yes, starting on the named mode" {
    for ([_]struct { command: []const u8, start: []const u8 }{
        .{ .command = "/auto", .start = "auto" },
        .{ .command = "/yolo", .start = "yolo" },
        .{ .command = "/yes", .start = "yolo" },
    }) |case| {
        var ctx: TestContext = .{};
        var handlers = testHandlers(&ctx);
        handlers.pick_permission_mode = recordPermissionPicker;
        try route(testSlashRegistry(), &handlers, case.command);
        try std.testing.expectEqualStrings("permission_picker", ctx.called);
        try std.testing.expectEqualStrings(case.start, ctx.payload);
    }
}

test "route switches the mode directly for /auto and /yolo when no picker is wired" {
    for ([_][]const u8{ "auto", "yolo" }) |mode| {
        var ctx: TestContext = .{};
        var handlers = testHandlers(&ctx);
        handlers.handle_permissions = recordPermissions;
        var command_buf: [8]u8 = undefined;
        const command = try std.fmt.bufPrint(&command_buf, "/{s}", .{mode});
        try route(testSlashRegistry(), &handlers, command);
        try std.testing.expectEqualStrings("permissions", ctx.called);
        try std.testing.expectEqualStrings(mode, ctx.payload);
    }
}

fn recordTower(ctx: *anyopaque, action: TowerAction) anyerror!void {
    testContext(ctx).called = "tower";
    testContext(ctx).payload = @tagName(action);
}

fn recordExportDebugZip(ctx: *anyopaque) anyerror!void {
    testContext(ctx).called = "export_debug_zip";
}

fn recordImportSessions(ctx: *anyopaque) anyerror!void {
    testContext(ctx).called = "import_sessions";
}

test "route dispatches the import-sessions command to its handler" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.import_sessions = recordImportSessions;

    try route(testSlashRegistry(), &handlers, "/import-sessions");
    try std.testing.expectEqualStrings("import_sessions", ctx.called);
}

fn recordTasks(ctx: *anyopaque, rest: []const u8) anyerror!void {
    testContext(ctx).called = "tasks";
    testContext(ctx).payload = rest;
}

fn recordExperiments(ctx: *anyopaque, rest: []const u8) anyerror!void {
    testContext(ctx).called = "experiments";
    testContext(ctx).payload = rest;
}

fn recordTheme(ctx: *anyopaque, rest: []const u8) anyerror!void {
    testContext(ctx).called = "theme";
    testContext(ctx).payload = rest;
}

fn recordPlan(ctx: *anyopaque, rest: []const u8) anyerror!void {
    testContext(ctx).called = "plan";
    testContext(ctx).payload = rest;
}

test "route dispatches the debug zip, tasks and experiments commands and their aliases" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.export_debug_zip = recordExportDebugZip;
    handlers.show_tasks = recordTasks;
    handlers.show_experiments = recordExperiments;

    try route(testSlashRegistry(), &handlers, "/export-debug-zip");
    try std.testing.expectEqualStrings("export_debug_zip", ctx.called);

    try route(testSlashRegistry(), &handlers, "/task");
    try std.testing.expectEqualStrings("tasks", ctx.called);

    try route(testSlashRegistry(), &handlers, "/experimental");
    try std.testing.expectEqualStrings("experiments", ctx.called);
}

test "route passes the task id and experiment flag to their handlers" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.show_tasks = recordTasks;
    handlers.show_experiments = recordExperiments;

    try route(testSlashRegistry(), &handlers, "/tasks exec-7");
    try std.testing.expectEqualStrings("tasks", ctx.called);
    try std.testing.expectEqualStrings("exec-7", ctx.payload);

    try route(testSlashRegistry(), &handlers, "/experiments wait_for on");
    try std.testing.expectEqualStrings("experiments", ctx.called);
    try std.testing.expectEqualStrings("wait_for on", ctx.payload);
}

test "route passes the theme name to the theme handler" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.handle_theme = recordTheme;

    try route(testSlashRegistry(), &handlers, "/theme  dark ");

    try std.testing.expectEqualStrings("theme", ctx.called);
    try std.testing.expectEqualStrings("dark", ctx.payload);
}

fn recordMcpConfig(ctx: *anyopaque, rest: []const u8) anyerror!void {
    testContext(ctx).called = "mcp_config";
    testContext(ctx).payload = rest;
}

test "route sends /mcp-config and its request to its own handler, never to /mcp" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.handle_mcp_config = recordMcpConfig;

    try route(testSlashRegistry(), &handlers, "/mcp-config  login linear ");
    try std.testing.expectEqualStrings("mcp_config", ctx.called);
    try std.testing.expectEqualStrings("login linear", ctx.payload);

    try route(testSlashRegistry(), &handlers, "/mcp-config");
    try std.testing.expectEqualStrings("mcp_config", ctx.called);
    try std.testing.expectEqualStrings("", ctx.payload);

    switch (parse(testSlashRegistry(), "/mcp list")) {
        .mcp => |rest| try std.testing.expectEqualStrings("list", rest),
        else => return error.TestExpectedEqual,
    }
}

fn recordRewind(ctx: *anyopaque, rest: []const u8) anyerror!void {
    testContext(ctx).called = "rewind";
    testContext(ctx).payload = rest;
}

test "route passes /rewind and its /checkpoint alias to the rewind handler with the scope" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.handle_rewind = recordRewind;

    try route(testSlashRegistry(), &handlers, "/rewind code");
    try std.testing.expectEqualStrings("rewind", ctx.called);
    try std.testing.expectEqualStrings("code", ctx.payload);

    ctx = .{};
    try route(testSlashRegistry(), &handlers, "/checkpoint");
    try std.testing.expectEqualStrings("rewind", ctx.called);
    try std.testing.expectEqualStrings("", ctx.payload);
}

test "route passes the plan argument to the plan handler" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.handle_plan = recordPlan;

    try route(testSlashRegistry(), &handlers, "/plan  off ");

    try std.testing.expectEqualStrings("plan", ctx.called);
    try std.testing.expectEqualStrings("off", ctx.payload);
}

test "route passes the tower action to the tower handler" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.handle_tower = recordTower;

    try route(testSlashRegistry(), &handlers, "/tower off");

    try std.testing.expectEqualStrings("tower", ctx.called);
    try std.testing.expectEqualStrings("exit", ctx.payload);
}

test "without a tower handler, /tower falls back to the unknown command" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.unknown = recordUnknown;

    try route(testSlashRegistry(), &handlers, "/tower on");

    try std.testing.expectEqualStrings("unknown", ctx.called);
    try std.testing.expectEqualStrings("/tower on", ctx.payload);
}

test "parse maps /auto to the auto mode and /exit aliases to quit" {
    try std.testing.expectEqual(ParsedCommand.auto_mode, parse(testSlashRegistry(), "/auto"));
    try std.testing.expectEqual(ParsedCommand.yolo_mode, parse(testSlashRegistry(), "/yolo"));
    try std.testing.expectEqual(ParsedCommand.yolo_mode, parse(testSlashRegistry(), "/yes"));
    try std.testing.expectEqual(ParsedCommand.quit, parse(testSlashRegistry(), "/exit"));
    try std.testing.expectEqual(ParsedCommand.quit, parse(testSlashRegistry(), "/quit"));
    try std.testing.expectEqual(ParsedCommand.quit, parse(testSlashRegistry(), "/q"));
}

test "provider arguments are handed to the provider handler, which owns its usage" {
    switch (parse(testSlashRegistry(), "/provider codex")) {
        .provider_argument => |rest| try std.testing.expectEqualStrings("codex", rest),
        else => return error.TestExpectedEqual,
    }
}

test "parse extracts allowlist command payload" {
    switch (parse(testSlashRegistry(), "/allowlist add command \"git *\"")) {
        .allowlist => |rest| try std.testing.expectEqualStrings("add command \"git *\"", rest),
        else => return error.TestExpectedEqual,
    }
}

test "parse extracts sound command payload" {
    switch (parse(testSlashRegistry(), "/sound off")) {
        .notifications => |rest| try std.testing.expectEqualStrings("off", rest),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/sound")) {
        .notifications => |rest| try std.testing.expectEqualStrings("", rest),
        else => return error.TestExpectedEqual,
    }
}

test "parse distinguishes new and reset lifecycle commands" {
    try std.testing.expectEqual(ParsedCommand.new_session, parse(testSlashRegistry(), "/new"));
    try std.testing.expectEqual(ParsedCommand.reset_session, parse(testSlashRegistry(), "/reset"));
}

test "parse recognizes interactive resume" {
    try std.testing.expectEqual(ParsedCommand.resume_session, parse(testSlashRegistry(), "/resume"));
}

test "parse recognizes fork without a payload" {
    try std.testing.expectEqual(ParsedCommand.fork_session, parse(testSlashRegistry(), "/fork"));
    switch (parse(testSlashRegistry(), "/fork 2")) {
        .fork_argument => |rest| try std.testing.expectEqualStrings("2", rest),
        else => return error.TestExpectedEqual,
    }
}

test "parse recognizes logout" {
    switch (parse(testSlashRegistry(), "/logout")) {
        .unknown => return error.TestExpectedLogoutCommand,
        else => {},
    }
}

test "parse rejects removed slash commands" {
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/pr ready for review"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/issue flaky test"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/changes"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/review"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/history"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/rules"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/background"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/alias build zig build"));
}

test "parse extracts image commands" {
    switch (parse(testSlashRegistry(), "/image screenshot.png")) {
        .image => |path| try std.testing.expectEqualStrings("screenshot.png", path),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/img screenshot.png")) {
        .image => |path| try std.testing.expectEqualStrings("screenshot.png", path),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/images clear")) {
        .images => |rest| try std.testing.expectEqualStrings("clear", rest),
        else => return error.TestExpectedEqual,
    }
}

test "parse extracts mcp command payload" {
    switch (parse(testSlashRegistry(), "/mcp add everything npx -y @modelcontextprotocol/server-everything")) {
        .mcp => |rest| try std.testing.expectEqualStrings("add everything npx -y @modelcontextprotocol/server-everything", rest),
        else => return error.TestExpectedEqual,
    }
}

test "parse recognizes exact no-payload commands" {
    try std.testing.expectEqual(ParsedCommand.copy, parse(testSlashRegistry(), "/copy"));
    try std.testing.expectEqual(ParsedCommand.feedback, parse(testSlashRegistry(), "/feedback"));
    try std.testing.expectEqual(ParsedCommand.trace, parse(testSlashRegistry(), "/trace"));
    switch (parse(testSlashRegistry(), "/compact")) {
        .compact => |instruction| try std.testing.expectEqualStrings("", instruction),
        else => return error.TestExpectedCompactCommand,
    }
    switch (parse(testSlashRegistry(), "/compact keep the schema decisions")) {
        .compact => |instruction| try std.testing.expectEqualStrings("keep the schema decisions", instruction),
        else => return error.TestExpectedCompactCommand,
    }
    try std.testing.expectEqual(ParsedCommand.credits, parse(testSlashRegistry(), "/credits"));
    try std.testing.expectEqual(ParsedCommand.credits, parse(testSlashRegistry(), "/balance"));
    try std.testing.expectEqual(ParsedCommand.paste, parse(testSlashRegistry(), "/paste"));
    try std.testing.expectEqual(ParsedCommand.version, parse(testSlashRegistry(), "/version"));
}

test "parse extracts fast command payload" {
    switch (parse(testSlashRegistry(), "/fast")) {
        .fast => |rest| try std.testing.expectEqualStrings("", rest),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/fast off")) {
        .fast => |rest| try std.testing.expectEqualStrings("off", rest),
        else => return error.TestExpectedEqual,
    }
}

test "parse extracts ultrafast command payload" {
    switch (parse(testSlashRegistry(), "/ultrafast")) {
        .ultrafast => |rest| try std.testing.expectEqualStrings("", rest),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/ultrafast status")) {
        .ultrafast => |rest| try std.testing.expectEqualStrings("status", rest),
        else => return error.TestExpectedEqual,
    }
}

test "parse extracts settings command payload" {
    switch (parse(testSlashRegistry(), "/settings")) {
        .settings => |rest| try std.testing.expectEqualStrings("", rest),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/settings startup-scrollback")) {
        .settings => |rest| try std.testing.expectEqualStrings("startup-scrollback", rest),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/settings startup-scrollback off")) {
        .settings => |rest| try std.testing.expectEqualStrings("startup-scrollback off", rest),
        else => return error.TestExpectedEqual,
    }
}

test "parse treats unknown and malformed command inputs as unknown" {
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/wat"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/output"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/output quiet"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/subagents"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "hello"));
    switch (parse(testSlashRegistry(), "/copy extra")) {
        .extension => |requested| try std.testing.expectEqual(SlashKind.copy, requested.kind),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), " /model claude-opus"));
}

test "parse tolerates trailing whitespace on exact-match commands" {
    try std.testing.expectEqual(ParsedCommand.quit, parse(testSlashRegistry(), "/exit "));
    try std.testing.expectEqual(ParsedCommand.quit, parse(testSlashRegistry(), "/quit  "));
    try std.testing.expectEqual(ParsedCommand.quit, parse(testSlashRegistry(), "/exit \t"));
    try std.testing.expectEqual(ParsedCommand.help, parse(testSlashRegistry(), "/help "));
    try std.testing.expectEqual(ParsedCommand.copy, parse(testSlashRegistry(), "/copy "));
    try std.testing.expectEqual(ParsedCommand.new_session, parse(testSlashRegistry(), "/clear\t"));
}

test "parse returns empty payload for bare prefix commands" {
    switch (parse(testSlashRegistry(), "/model")) {
        .model => |query| try std.testing.expectEqualStrings("", query),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/mcp")) {
        .mcp => |rest| try std.testing.expectEqualStrings("", rest),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/allowlist")) {
        .allowlist => |rest| try std.testing.expectEqualStrings("", rest),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/skills")) {
        .skills => |rest| try std.testing.expectEqualStrings("", rest),
        else => return error.TestExpectedEqual,
    }
}

test "parse trims only spaces and tabs around payload" {
    switch (parse(testSlashRegistry(), "/model \t claude-opus \t")) {
        .model => |query| try std.testing.expectEqualStrings("claude-opus", query),
        else => return error.TestExpectedEqual,
    }
}

fn recordExtension(ctx: *anyopaque, kind: SlashKind, rest: []const u8) anyerror!void {
    testContext(ctx).called = @tagName(kind);
    testContext(ctx).payload = rest;
}

test "route hands the Claude Code commands and their arguments to the extension handler" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.handle_extension = recordExtension;
    handlers.resume_session = recordResumeSession;
    handlers.copy_last = recordCopy;

    try route(testSlashRegistry(), &handlers, "/continue  release notes ");
    try std.testing.expectEqualStrings("resume_session", ctx.called);
    try std.testing.expectEqualStrings("release notes", ctx.payload);

    try route(testSlashRegistry(), &handlers, "/resume");
    try std.testing.expectEqualStrings("resume", ctx.called);

    try route(testSlashRegistry(), &handlers, "/copy 2");
    try std.testing.expectEqualStrings("copy", ctx.called);
    try std.testing.expectEqualStrings("2", ctx.payload);

    try route(testSlashRegistry(), &handlers, "/copy");
    try std.testing.expectEqualStrings("copy", ctx.called);

    const cases = [_]struct { line: []const u8, kind: []const u8, rest: []const u8 }{
        .{ .line = "/rewind", .kind = "rewind", .rest = "" },
        .{ .line = "/checkpoint", .kind = "rewind", .rest = "" },
        .{ .line = "/init focus on the build", .kind = "init", .rest = "focus on the build" },
        .{ .line = "/diff", .kind = "diff", .rest = "" },
        .{ .line = "/memory", .kind = "memory", .rest = "" },
        .{ .line = "/hooks", .kind = "hooks", .rest = "" },
        .{ .line = "/checkup", .kind = "doctor", .rest = "" },
        .{ .line = "/proactive 5m check the deploy", .kind = "loop", .rest = "5m check the deploy" },
        .{ .line = "/branch spike", .kind = "branch", .rest = "spike" },
        .{ .line = "/context", .kind = "context", .rest = "" },
        .{ .line = "/autocompact 60", .kind = "autocompact", .rest = "60" },
    };
    for (cases) |case| {
        try route(testSlashRegistry(), &handlers, case.line);
        try std.testing.expectEqualStrings(case.kind, ctx.called);
        try std.testing.expectEqualStrings(case.rest, ctx.payload);
    }
}

test "without an extension handler the Claude Code commands fall back to the unknown command" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.unknown = recordUnknown;
    try route(testSlashRegistry(), &handlers, "/diff");
    try std.testing.expectEqualStrings("unknown", ctx.called);
}

fn parsedIsUnknown(parsed: ParsedCommand) bool {
    return switch (parsed) {
        .unknown => true,
        else => false,
    };
}

test "parse covers every registered slash command token and alias" {
    for (testSlashRegistry().commands) |spec| {
        try std.testing.expect(!parsedIsUnknown(parse(testSlashRegistry(), spec.command)));
        for (spec.aliases) |alias| {
            try std.testing.expect(!parsedIsUnknown(parse(testSlashRegistry(), alias)));
        }
    }
}

test "parse payload acceptance follows slash spec metadata" {
    var buf: [128]u8 = undefined;
    for (testSlashRegistry().commands) |spec| {
        const command_with_payload = try std.mem.print(&buf, "{s} sample", .{spec.command});
        const parsed = parse(testSlashRegistry(), command_with_payload);
        if (spec.accepts_payload) {
            try std.testing.expect(!parsedIsUnknown(parsed));
        } else {
            try std.testing.expect(parsedIsUnknown(parsed));
        }
    }
}

const TestContext = struct {
    called: []const u8 = "",
    payload: []const u8 = "",
};

fn testContext(ctx: *anyopaque) *TestContext {
    return @ptrCast(@alignCast(ctx));
}

fn unexpectedNoPayload(ctx: *anyopaque) anyerror!void {
    _ = ctx;
    return error.UnexpectedCallback;
}

fn unexpectedPayload(ctx: *anyopaque, value: []const u8) anyerror!void {
    _ = ctx;
    _ = value;
    return error.UnexpectedCallback;
}

fn recordShell(ctx: *anyopaque, value: []const u8) anyerror!void {
    testContext(ctx).called = "shell";
    testContext(ctx).payload = value;
}

fn recordCopy(ctx: *anyopaque) anyerror!void {
    testContext(ctx).called = "copy";
}

fn recordResumeSession(ctx: *anyopaque) anyerror!void {
    testContext(ctx).called = "resume";
}

fn recordForkSession(ctx: *anyopaque) anyerror!void {
    testContext(ctx).called = "fork";
}

fn recordModel(ctx: *anyopaque, value: []const u8) anyerror!void {
    const test_context = testContext(ctx);
    test_context.called = "model";
    test_context.payload = value;
}

fn recordAllowlist(ctx: *anyopaque, value: []const u8) anyerror!void {
    const test_context = testContext(ctx);
    test_context.called = "allowlist";
    test_context.payload = value;
}

fn recordSettings(ctx: *anyopaque, value: []const u8) anyerror!void {
    const test_context = testContext(ctx);
    test_context.called = "settings";
    test_context.payload = value;
}

fn recordNotifications(ctx: *anyopaque, value: []const u8) anyerror!void {
    const test_context = testContext(ctx);
    test_context.called = "notifications";
    test_context.payload = value;
}

fn recordUnknown(ctx: *anyopaque, value: []const u8) anyerror!void {
    const test_context = testContext(ctx);
    test_context.called = "unknown";
    test_context.payload = value;
}

fn failStatus(ctx: *anyopaque) anyerror!void {
    _ = ctx;
    return error.TestRouteFailure;
}

fn testHandlers(ctx: *TestContext) CommandHandlers {
    return .{
        .ctx = ctx,
        .quit = unexpectedNoPayload,
        .new_session = unexpectedNoPayload,
        .launch_instance = unexpectedPayload,
        .close_instance = unexpectedNoPayload,
        .show_agents = unexpectedNoPayload,
        .reset_session = unexpectedNoPayload,
        .resume_session = unexpectedNoPayload,
        .fork_session = unexpectedNoPayload,
        .show_help = unexpectedNoPayload,
        .login = unexpectedNoPayload,
        .logout = unexpectedPayload,
        .provider = unexpectedNoPayload,
        .setup_alias = unexpectedNoPayload,
        .show_status = unexpectedNoPayload,
        .attach_image = unexpectedPayload,
        .manage_images = unexpectedPayload,
        .handle_model = unexpectedPayload,
        .handle_effort = unexpectedPayload,
        .handle_permissions = unexpectedPayload,
        .handle_allowlist = unexpectedPayload,
        .show_stats = unexpectedNoPayload,
        .show_usage = unexpectedNoPayload,
        .undo_last = unexpectedNoPayload,
        .handle_mcp = unexpectedPayload,
        .handle_skills = unexpectedPayload,
        .handle_plugins = unexpectedPayload,
        .copy_last = unexpectedNoPayload,
        .submit_feedback = unexpectedNoPayload,
        .create_trace = unexpectedNoPayload,
        .compact_history = unexpectedPayload,
        .export_md = unexpectedPayload,
        .handle_settings = unexpectedPayload,
        .show_credits = unexpectedNoPayload,
        .paste_clipboard = unexpectedNoPayload,
        .handle_fast = unexpectedPayload,
        .handle_ultrafast = unexpectedPayload,
        .handle_statusline = unexpectedPayload,
        .rename_session = unexpectedPayload,
        .handle_notifications = unexpectedPayload,
        .handle_workspace = unexpectedPayload,
        .handle_shell = unexpectedPayload,
        .handle_parity = unexpectedPayload,
        .export_debug_zip = unexpectedNoPayload,
        .show_tasks = unexpectedPayload,
        .show_experiments = unexpectedPayload,
        .handle_theme = unexpectedPayload,
        .handle_plan = unexpectedPayload,
        .handle_mcp_config = unexpectedPayload,
        .show_version = unexpectedNoPayload,
        .unknown = unexpectedPayload,
    };
}

test "route passes shell payload" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.handle_shell = recordShell;

    try route(testSlashRegistry(), &handlers, "/shell reload");

    try std.testing.expectEqualStrings("shell", ctx.called);
    try std.testing.expectEqualStrings("reload", ctx.payload);
}

test "/setup warns through its own handler and /provider does not" {
    const Record = struct {
        fn provider(ctx: *anyopaque) anyerror!void {
            testContext(ctx).called = "provider";
        }
        fn setupAlias(ctx: *anyopaque) anyerror!void {
            testContext(ctx).called = "setup_alias";
        }
    };
    for ([_]struct { cmd: []const u8, called: []const u8 }{
        .{ .cmd = "/provider", .called = "provider" },
        .{ .cmd = deprecated_setup_alias, .called = "setup_alias" },
    }) |case| {
        var ctx: TestContext = .{};
        var handlers = testHandlers(&ctx);
        handlers.provider = Record.provider;
        handlers.setup_alias = Record.setupAlias;
        try route(testSlashRegistry(), &handlers, case.cmd);
        try std.testing.expectEqualStrings(case.called, ctx.called);
    }
}

test "route calls expected no-payload handler" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.copy_last = recordCopy;

    try route(testSlashRegistry(), &handlers, "/copy");

    try std.testing.expectEqualStrings("copy", ctx.called);
    try std.testing.expectEqualStrings("", ctx.payload);
}

test "route calls interactive resume handler" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.resume_session = recordResumeSession;

    try route(testSlashRegistry(), &handlers, "/resume");

    try std.testing.expectEqualStrings("resume", ctx.called);
}

test "route calls fork handler" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.fork_session = recordForkSession;

    try route(testSlashRegistry(), &handlers, "/fork");

    try std.testing.expectEqualStrings("fork", ctx.called);
}

test "route forwards borrowed payload slice" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.handle_model = recordModel;
    const cmd = "/model claude-opus";

    try route(testSlashRegistry(), &handlers, cmd);

    try std.testing.expectEqualStrings("model", ctx.called);
    try std.testing.expectEqualStrings("claude-opus", ctx.payload);
    try std.testing.expect(ctx.payload.ptr == cmd["/model ".len..].ptr);
}

test "route forwards allowlist payload" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.handle_allowlist = recordAllowlist;
    const cmd = "/allowlist add tool read_file";

    try route(testSlashRegistry(), &handlers, cmd);

    try std.testing.expectEqualStrings("allowlist", ctx.called);
    try std.testing.expectEqualStrings("add tool read_file", ctx.payload);
}

test "route forwards settings payload" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.handle_settings = recordSettings;
    const cmd = "/settings startup-scrollback off";

    try route(testSlashRegistry(), &handlers, cmd);

    try std.testing.expectEqualStrings("settings", ctx.called);
    try std.testing.expectEqualStrings("startup-scrollback off", ctx.payload);
}

test "route forwards notifications payload" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.handle_notifications = recordNotifications;
    const cmd = "/sound off";

    try route(testSlashRegistry(), &handlers, cmd);

    try std.testing.expectEqualStrings("notifications", ctx.called);
    try std.testing.expectEqualStrings("off", ctx.payload);
}

test "route sends original command string to unknown handler" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.unknown = recordUnknown;
    const cmd = " /wat untouched";

    try route(testSlashRegistry(), &handlers, cmd);

    try std.testing.expectEqualStrings("unknown", ctx.called);
    try std.testing.expectEqualStrings(cmd, ctx.payload);
    try std.testing.expect(ctx.payload.ptr == cmd.ptr);
}

test "route propagates callback errors" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.show_status = failStatus;

    try std.testing.expectError(error.TestRouteFailure, route(testSlashRegistry(), &handlers, "/status"));
}

test "parse extracts plugins payload and the /permission alias" {
    switch (parse(testSlashRegistry(), "/plugins mcp enable acme search")) {
        .plugins => |rest| try std.testing.expectEqualStrings("mcp enable acme search", rest),
        else => return error.TestExpectedPluginsCommand,
    }
    switch (parse(testSlashRegistry(), "/plugins")) {
        .plugins => |rest| try std.testing.expectEqualStrings("", rest),
        else => return error.TestExpectedPluginsCommand,
    }
    switch (parse(testSlashRegistry(), "/permission auto")) {
        .permissions => |rest| try std.testing.expectEqualStrings("auto", rest),
        else => return error.TestExpectedPermissionsAlias,
    }
}

test "route forwards plugins payload" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.handle_plugins = recordPlugins;

    try route(testSlashRegistry(), &handlers, "/plugins enable acme");

    try std.testing.expectEqualStrings("plugins", ctx.called);
    try std.testing.expectEqualStrings("enable acme", ctx.payload);
}

fn recordPlugins(ctx: *anyopaque, value: []const u8) anyerror!void {
    const test_context = testContext(ctx);
    test_context.called = "plugins";
    test_context.payload = value;
}

test "parse reads /swarm with its mode word or task" {
    switch (parse(testSlashRegistry(), "/swarm")) {
        .swarm => |rest| try std.testing.expectEqualStrings("", rest),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/swarm  audit every package ")) {
        .swarm => |rest| try std.testing.expectEqualStrings("audit every package", rest),
        else => return error.TestExpectedEqual,
    }
}

test "without a swarm handler, /swarm falls back to the unknown command" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.unknown = recordUnknown;

    try route(testSlashRegistry(), &handlers, "/swarm on");
    try std.testing.expectEqualStrings("unknown", ctx.called);
    try std.testing.expectEqualStrings("/swarm on", ctx.payload);
}

pub const undo_count_usage = "Usage: /undo [count], where count is a positive integer.";

pub fn undoCount(rest: []const u8) ?usize {
    const count = std.fmt.parseUnsigned(usize, std.mem.trim(u8, rest, " \t"), 10) catch return null;
    return if (count == 0) null else count;
}

test "/undo alone keeps the file undo and /undo with a count asks to withdraw that many prompts" {
    try std.testing.expectEqual(ParsedCommand.undo, parse(testSlashRegistry(), "/undo"));
    try std.testing.expectEqual(ParsedCommand.undo, parse(testSlashRegistry(), "/undo  "));
    switch (parse(testSlashRegistry(), "/undo 2")) {
        .withdraw_prompts => |rest| try std.testing.expectEqualStrings("2", rest),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqual(@as(?usize, 2), undoCount(" 2 "));
    try std.testing.expectEqual(@as(?usize, null), undoCount("0"));
    try std.testing.expectEqual(@as(?usize, null), undoCount("two"));
    try std.testing.expectEqual(@as(?usize, null), undoCount("-1"));
}

pub const new_session_name_refusal = "usage: /new [name], where name is one line of printable text that titles the conversation you leave";

test "/clear alone starts a fresh session and /clear with a name asks to title the one it leaves" {
    try std.testing.expectEqual(ParsedCommand.new_session, parse(testSlashRegistry(), "/new"));
    try std.testing.expectEqual(ParsedCommand.new_session, parse(testSlashRegistry(), "/clear  "));
    switch (parse(testSlashRegistry(), "/clear uploader fix")) {
        .new_session_named => |rest| try std.testing.expectEqualStrings("uploader fix", rest),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/new  release notes ")) {
        .new_session_named => |rest| try std.testing.expectEqualStrings("release notes", rest),
        else => return error.TestExpectedEqual,
    }
}

pub const fork_usage = "usage: /fork [copy]";

pub fn forkAsksForWholeCopy(rest: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, rest, " \t"), "copy");
}

test "/fork alone opens the fork menu and /fork copy asks for a whole copy" {
    try std.testing.expectEqual(ParsedCommand.fork_session, parse(testSlashRegistry(), "/fork"));
    switch (parse(testSlashRegistry(), "/fork copy")) {
        .fork_argument => |rest| try std.testing.expect(forkAsksForWholeCopy(rest)),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expect(forkAsksForWholeCopy(" COPY "));
    try std.testing.expect(!forkAsksForWholeCopy("now"));
}

pub const provider_usage = "usage: /provider [refresh]";

pub fn providerAsksForRefresh(rest: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, rest, " \t"), "refresh");
}

test "/provider alone opens the provider picker and /provider refresh asks for the model list again" {
    try std.testing.expectEqual(ParsedCommand.provider, parse(testSlashRegistry(), "/provider"));
    try std.testing.expectEqual(ParsedCommand.provider, parse(testSlashRegistry(), "/providers"));
    switch (parse(testSlashRegistry(), "/providers refresh")) {
        .provider_argument => |rest| try std.testing.expect(providerAsksForRefresh(rest)),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expect(!providerAsksForRefresh("delete"));
}

test "parse reads /secondary-model and its /subagent-model alias with an optional model" {
    switch (parse(testSlashRegistry(), "/secondary-model")) {
        .secondary_model => |rest| try std.testing.expectEqualStrings("", rest),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/subagent-model provider/small-model")) {
        .secondary_model => |rest| try std.testing.expectEqualStrings("provider/small-model", rest),
        else => return error.TestExpectedEqual,
    }
}

test "parse reads /editor alone and with an editor command" {
    switch (parse(testSlashRegistry(), "/editor")) {
        .editor => |rest| try std.testing.expectEqualStrings("", rest),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/editor code --wait")) {
        .editor => |rest| try std.testing.expectEqualStrings("code --wait", rest),
        else => return error.TestExpectedEqual,
    }
}

test "/reload and /reload-tui are separate commands" {
    try std.testing.expectEqual(ParsedCommand.reload, parse(testSlashRegistry(), "/reload"));
    try std.testing.expectEqual(ParsedCommand.reload_tui, parse(testSlashRegistry(), "/reload-tui"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/reload-everything"));
}

test "parse reads /btw with its question" {
    switch (parse(testSlashRegistry(), "/btw which file holds the parser?")) {
        .side_question => |rest| try std.testing.expectEqualStrings("which file holds the parser?", rest),
        else => return error.TestExpectedEqual,
    }
}
