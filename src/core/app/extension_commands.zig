const std = @import("std");
const agents = @import("../agents/agents.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const host_target = @import("../hosts/target.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const config_runtime = @import("../config/config_runtime.zig");
const settings_keys = @import("../config/settings_keys.zig");
const cli_config = @import("../cli/cli_config.zig");
const settings_messages = @import("../cli/settings_messages.zig");
const external_hooks = @import("../hooks/external.zig");
const git_context = @import("../github/git_context.zig");
const builtin_context = @import("../../builtins/context.zig");
const prompt_commands = @import("../../builtins/prompt_commands.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const self_exe = @import("../shared/self_exe.zig");
const io_mod = @import("../shared/io.zig");
const keybindings = @import("../input/keybindings.zig");
const output_styles = @import("../output/output_styles.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const context_usage = @import("../output/context_usage.zig");
const compactor = @import("../compactor/compactor.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const provider_runtime = @import("provider_runtime.zig");

const Allocator = std.mem.Allocator;
const SlashKind = command_specs.SlashKind;

pub fn handle(app: anytype, agent: anytype, kind: SlashKind, rest: []const u8) !void {
    switch (kind) {
        .resume_session => try resumeNamed(app, agent, rest),
        .copy => try copyNthReply(app, agent, rest),
        .rewind => try rewind(app, agent),
        .init => try submitInit(app, agent, rest),
        .diff => try showWorkingTreeDiff(app),
        .memory => try showInstructionFiles(app),
        .hooks => try showHooks(app),
        .doctor => try runDoctor(app),
        .loop => try scheduleLoop(app, agent, rest),
        .branch => try branch(app, agent, rest),
        .context => try showContextUsage(app, agent),
        .autocompact => try autoCompactThreshold(app, agent, rest),
        .keybindings => try reloadKeybindings(app),
        .output_style => try switchOutputStyle(app, rest),
        else => try say(app, "", .@"error", "that command takes no arguments"),
    }
}

fn reloadKeybindings(app: anytype) !void {
    switch (try keybindings.reloadUserFile(app.alloc)) {
        .no_home => try say(app, "keybindings", .warning, "No home directory, so there is no keybindings file to read."),
        .write_failed => |err| try sayOwned(app, "keybindings", .@"error", try std.fmt.allocPrint(
            app.alloc,
            "Could not create the keybindings file: {s}",
            .{@errorName(err)},
        )),
        .report => |report| try sayOwned(app, "keybindings", .neutral, report),
    }
}

fn switchOutputStyle(app: anytype, requested: []const u8) !void {
    const outcome = try output_styles.switchTo(app.alloc, io_mod.homeDir(), requested);
    const unknown_name = !outcome.changed and std.mem.trim(u8, requested, " \t").len > 0;
    try sayOwned(app, "output style", if (unknown_name) .@"error" else .neutral, outcome.message);
}

fn say(app: anytype, topic: []const u8, tone: types.NoticeTone, body: []const u8) !void {
    try app.writeDomainNotice(.{ .topic = topic, .tone = tone, .body = body }, true);
}

fn sayOwned(app: anytype, topic: []const u8, tone: types.NoticeTone, body: []u8) !void {
    defer app.alloc.free(body);
    try say(app, topic, tone, body);
}

const sessions_unavailable = "Saved sessions are owned by the embedding SDK for this host.";

fn resumeNamed(app: anytype, agent: anytype, reference: []const u8) !void {
    const App = @TypeOf(app.*);
    if (comptime !runtime_profile.allows(App, .durable_sessions) or
        !agents.hasAgentField(App, "session_persistence") or
        !@hasDecl(App, "prepareLiveSessionResume") or
        !@hasDecl(App, "finishLiveSessionResume"))
    {
        return say(app, "session", .warning, sessions_unavailable);
    }
    const resumed = app_session_runtime.Runtime(App).resumeNamedSession(app, agent, reference) catch |err| {
        return sayOwned(app, "session", .@"error", try std.fmt.allocPrint(
            app.alloc,
            "Unable to resume \"{f}\": {s}. Run /resume to pick a session.",
            .{ text_utils.terminalSafe(reference), @errorName(err) },
        ));
    };
    if (!resumed) try say(app, "session", .warning, "/resume needs a saved session store");
}

fn branch(app: anytype, agent: anytype, name: []const u8) !void {
    const App = @TypeOf(app.*);
    if (comptime !runtime_profile.allows(App, .durable_sessions) or
        !agents.hasAgentField(App, "session_persistence") or
        !agents.hasAgentField(App, "stream") or
        !@hasDecl(App, "prepareLiveSessionResume") or
        !@hasDecl(App, "finishLiveSessionResume"))
    {
        return say(app, "session", .warning, sessions_unavailable);
    }
    if (agent.stream.active) return say(app, "session", .neutral, "/branch is available once the current turn finishes");
    app_session_runtime.Runtime(App).branchActiveSession(app, agent, name) catch |err| {
        const reason: []const u8 = switch (err) {
            error.NoActiveSession => "/branch needs a saved session",
            error.EmptyTitle => "the branch name must not be empty",
            error.MultilineTitle => "the branch name must be one line",
            error.InvalidTitle => "the branch name must be printable text",
            else => return sayOwned(app, "session", .@"error", try std.fmt.allocPrint(
                app.alloc,
                "Unable to branch this conversation: {s}",
                .{@errorName(err)},
            )),
        };
        return say(app, "session", .@"error", reason);
    };
}

fn autoCompactThreshold(app: anytype, agent: anytype, rest: []const u8) !void {
    const App = @TypeOf(app.*);
    if (comptime !agents.hasAgentField(App, "worker")) {
        return say(app, "compaction", .warning, "This host does not set an automatic compaction threshold.");
    }
    const Worker = @TypeOf(agent.worker);
    if (comptime @typeInfo(Worker) != .@"struct" or !@hasField(Worker, "agent_turn_settings")) {
        return say(app, "compaction", .warning, "This host does not set an automatic compaction threshold.");
    }
    if (std.mem.trim(u8, rest, " \t").len == 0) {
        return sayOwned(app, "compaction", .neutral, try std.fmt.allocPrint(
            app.alloc,
            "Automatic compaction starts at {d}% of usable input. /autocompact PERCENT changes it for this session; fx config set auto_compact_percent PERCENT keeps it.",
            .{agent.worker.agent_turn_settings.auto_compact_percent},
        ));
    }
    const percent = compactor.parseCommandPercent(rest) orelse
        return say(app, "compaction", .@"error", compactor.command_usage);
    agent.worker.agent_turn_settings.auto_compact_percent = percent;
    try sayOwned(app, "compaction", .neutral, try std.fmt.allocPrint(
        app.alloc,
        "Automatic compaction now starts at {d}% of usable input for this session.",
        .{percent},
    ));
}

fn showContextUsage(app: anytype, agent: anytype) !void {
    const App = @TypeOf(app.*);
    if (comptime !agents.hasAgentField(App, "total_input_tokens")) {
        return say(app, "context", .warning, "This host does not report context usage.");
    }
    const window = model_capabilities.resolveForApp(App, app, provider_runtime.modelOf(app, agent)).context_window;
    try sayOwned(app, "context", .neutral, try context_usage.render(app.alloc, agents.loadTotal(&agent.total_input_tokens), window));
}

fn rewind(app: anytype, agent: anytype) !void {
    const App = @TypeOf(app.*);
    if (comptime !runtime_profile.allows(App, .durable_sessions) or
        !agents.hasAgentField(App, "session_persistence") or
        !agents.hasAgentField(App, "stream"))
    {
        return say(app, "session", .warning, sessions_unavailable);
    }
    if (agent.stream.active) return say(app, "session", .neutral, "/rewind is available once the current turn finishes");
    try app_session_runtime.Runtime(App).openUndoSelector(app, agent);
}

pub fn replyOrdinal(rest: []const u8) ?usize {
    const ordinal = std.fmt.parseUnsigned(usize, std.mem.trim(u8, rest, " \t"), 10) catch return null;
    return if (ordinal == 0) null else ordinal;
}

const copy_usage = "usage: /copy [N], where N counts back from the latest reply and 1 is the latest";

fn copyNthReply(app: anytype, agent: anytype, rest: []const u8) !void {
    const ordinal = replyOrdinal(rest) orelse return say(app, "", .@"error", copy_usage);
    const reply = if (comptime @hasDecl(@TypeOf(agent.session), "nthAssistantReply"))
        agent.session.nthAssistantReply(ordinal)
    else if (comptime @hasDecl(@TypeOf(agent.session), "lastAssistantReply"))
        if (ordinal == 1) agent.session.lastAssistantReply() else null
    else
        null;
    const text = reply orelse return sayOwned(app, "clipboard", .neutral, try std.fmt.allocPrint(
        app.alloc,
        "There is no assistant reply {d} back to copy.",
        .{ordinal},
    ));
    const copied = app.clipboard().copy(text) catch false;
    if (!copied) return say(app, "clipboard", .@"error", "Failed to copy to clipboard.");
    try sayOwned(app, "clipboard", .neutral, try std.fmt.allocPrint(
        app.alloc,
        "Copied reply {d} back to clipboard.",
        .{ordinal},
    ));
}

const prompt_unavailable = "This host cannot start a turn from a slash command.";

fn submitInit(app: anytype, agent: anytype, rest: []const u8) !void {
    const App = @TypeOf(app.*);
    if (comptime !@hasDecl(App, "submitCommandPrompt")) return say(app, "", .warning, prompt_unavailable);
    const prompt = try prompt_commands.initPrompt(app.alloc, rest);
    defer app.alloc.free(prompt);
    try app.submitCommandPrompt(agent, "init", prompt);
}

const loop_usage = "usage: /loop [interval] <prompt>, with an interval such as 30s, 5m, 2h or 1d (default 10m)";

fn scheduleLoop(app: anytype, agent: anytype, rest: []const u8) !void {
    const App = @TypeOf(app.*);
    if (comptime !@hasDecl(App, "submitCommandPrompt")) return say(app, "", .warning, prompt_unavailable);
    const request = prompt_commands.parseLoop(rest) orelse return say(app, "", .@"error", loop_usage);
    const prompt = try prompt_commands.loopPrompt(app.alloc, request);
    defer app.alloc.free(prompt);
    try app.submitCommandPrompt(agent, "loop", prompt);
}

const subprocess_unavailable = "This host cannot run local commands.";

fn showWorkingTreeDiff(app: anytype) !void {
    const App = @TypeOf(app.*);
    if (comptime host_target.is_wasm or !runtime_profile.allows(App, .tools)) return say(app, "diff", .warning, subprocess_unavailable);
    if (comptime @hasDecl(App, "flushBeforeBlockingExternalWork")) try app.flushBeforeBlockingExternalWork();
    try sayOwned(app, "diff", .neutral, try git_context.workingTreeDiff(app.alloc));
}

const doctor_output_limit: usize = 64 * 1024;

fn runDoctor(app: anytype) !void {
    const App = @TypeOf(app.*);
    if (comptime host_target.is_wasm or !runtime_profile.allows(App, .tools)) return say(app, "doctor", .warning, subprocess_unavailable);
    if (comptime @hasDecl(App, "flushBeforeBlockingExternalWork")) try app.flushBeforeBlockingExternalWork();

    const executable = self_exe.pathForReexec(app.alloc) catch
        return say(app, "doctor", .@"error", "fx could not find its own executable to run the checks; run `fx doctor` in a shell.");
    defer app.alloc.free(executable);
    const result = std.process.run(app.alloc, io_mod.getIo(), .{
        .argv = &.{ executable, "doctor" },
        .stdout_limit = .limited(doctor_output_limit),
        .stderr_limit = .limited(doctor_output_limit),
    }) catch |err| {
        return sayOwned(app, "doctor", .@"error", try std.fmt.allocPrint(
            app.alloc,
            "fx could not run its checks ({s}); run `fx doctor` in a shell.",
            .{@errorName(err)},
        ));
    };
    defer app.alloc.free(result.stdout);
    defer app.alloc.free(result.stderr);

    const report = std.mem.trim(u8, result.stdout, " \t\r\n");
    const passed = result.term == .exited and result.term.exited == 0;
    if (report.len == 0) {
        const detail = std.mem.trim(u8, result.stderr, " \t\r\n");
        return say(app, "doctor", .@"error", if (detail.len > 0) detail else "fx doctor printed no report.");
    }
    try say(app, "doctor", if (passed) .neutral else .warning, report);
}

pub const InstructionFile = struct {
    path: []const u8,
    bytes: ?u64,
};

pub fn renderInstructionFiles(alloc: Allocator, files: []const InstructionFile) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const writer = &out.writer;
    writeInstructionFiles(writer, files) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeInstructionFiles(writer: *std.Io.Writer, files: []const InstructionFile) std.Io.Writer.Error!void {
    var loaded: usize = 0;
    for (files) |file| loaded += @intFromBool(file.bytes != null);
    if (loaded == 0) {
        try writer.writeAll("No instruction files yet. Run /init to write an AGENTS.md for this workspace.\n");
    } else {
        try writer.writeAll("Instruction files fx reads at the start of a session:\n");
    }
    for (files) |file| {
        if (file.bytes) |bytes| {
            try writer.print("  {f} ({d} bytes)\n", .{ text_utils.terminalSafe(file.path), bytes });
        } else {
            try writer.print("  {f} (not present)\n", .{text_utils.terminalSafe(file.path)});
        }
    }
    try writer.writeAll("Edit a file in your editor, or ask fx to change it; the change applies to the next session. fx keeps no automatic memory.");
}

fn fileBytes(path: []const u8) ?u64 {
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{ .follow_symlinks = true }) catch return null;
    return stat.size;
}

fn showInstructionFiles(app: anytype) !void {
    const App = @TypeOf(app.*);
    if (comptime host_target.is_wasm or !runtime_profile.allows(App, .tools)) return say(app, "memory", .warning, "This host supplies the instruction files itself.");

    var arena_state = std.heap.ArenaAllocator.init(app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var files: std.ArrayList(InstructionFile) = .empty;
    if (io_mod.homeDir()) |home| {
        const profile_file = try profile_paths.rootPath(arena, home, &.{"AGENTS.md"});
        try files.append(arena, .{ .path = profile_file, .bytes = fileBytes(profile_file) });
        const shared_file = try std.Io.Dir.path.join(arena, &.{ home, ".agents", builtin_context.agents_md_file_names[0] });
        try files.append(arena, .{ .path = shared_file, .bytes = fileBytes(shared_file) });
    }
    const project_file = try std.Io.Dir.path.join(arena, &.{ app.workspace_root, builtin_context.agents_md_file_names[0] });
    try files.append(arena, .{ .path = project_file, .bytes = fileBytes(project_file) });

    try sayOwned(app, "memory", .neutral, try renderInstructionFiles(app.alloc, files.items));
}

pub fn renderHooks(alloc: Allocator, definitions: []const external_hooks.Definition) Allocator.Error![]u8 {
    if (definitions.len == 0) {
        return std.fmt.allocPrint(
            alloc,
            "No hooks are configured. Add a \"hooks\" block to {s}, for example {s}, then restart fx and run /hooks to check it.",
            .{ profile_paths.displayText("~/.fx/settings.json"), first_hook_example },
        );
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    writeHooks(&out.writer, definitions) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

const first_hook_example = "{\"hooks\":{\"Notification\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"notify-send fx\"}]}]}}";

fn writeHooks(writer: *std.Io.Writer, definitions: []const external_hooks.Definition) std.Io.Writer.Error!void {
    try writer.print("{d} hook{s} registered for this session, by event:", .{ definitions.len, if (definitions.len == 1) "" else "s" });
    for (definitions, 0..) |first, index| {
        if (eventListedBefore(definitions[0..index], first.event)) continue;
        try writer.print("\n{s}", .{@tagName(first.event)});
        if (!first.event.emitted()) try writer.writeAll(" (fx never fires this event)");
        for (definitions[index..]) |definition| {
            if (definition.event != first.event) continue;
            try writer.writeAll("\n  ");
            if (definition.matcher) |matcher| try writer.print("[{f}] ", .{text_utils.terminalSafe(matcher)});
            try writer.print("{f} (timeout {d}s", .{ text_utils.terminalSafe(definition.command), definition.timeout_seconds });
            if (definition.on_failure == .block) try writer.writeAll(", blocks when it fails");
            try writer.writeByte(')');
        }
    }
}

fn eventListedBefore(earlier: []const external_hooks.Definition, event: external_hooks.Event) bool {
    for (earlier) |definition| {
        if (definition.event == event) return true;
    }
    return false;
}

fn showHooks(app: anytype) !void {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "command_hooks") and @hasField(@FieldType(App, "command_hooks"), "definitions")) {
        if (app.command_hooks.definitions) |registered| {
            return sayOwned(app, "hooks", .neutral, try renderHooks(app.alloc, registered));
        }
    }
    var settings = config_runtime.loadMergedSettings(app.alloc, app.workspace_root) catch |err| {
        return sayOwned(app, "hooks", .@"error", try std.fmt.allocPrint(app.alloc, "Could not load settings: {s}", .{@errorName(err)}));
    };
    defer settings.deinit(app.alloc);
    try sayOwned(app, "hooks", .neutral, try renderHooks(app.alloc, settings.hooks orelse &.{}));
}

pub const SettingsRequest = union(enum) {
    help,
    assignments: []const u8,
};

pub fn settingsRequest(rest: []const u8) ?SettingsRequest {
    const text = std.mem.trim(u8, rest, " \t");
    if (std.mem.eql(u8, text, "--help") or std.mem.eql(u8, text, "-h")) return .help;
    const first = text[0 .. std.mem.findAny(u8, text, " \t") orelse text.len];
    if (std.mem.findScalar(u8, first, '=') == null) return null;
    return .{ .assignments = text };
}

pub fn settingsHelp(alloc: Allocator) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    writeSettingsHelp(&out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeSettingsHelp(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("usage: /settings [key=value ...]\nWith no argument, /settings opens the settings menu. key=value saves one setting. Keys:");
    inline for (cli_config.settable_keys) |key| try writer.print("\n  {s}", .{key});
}

pub const Assignment = union(enum) {
    change: struct { key: []const u8, value: []const u8, patch: config_runtime.UserSettingsPatch },
    problem: []u8,

    pub fn deinit(self: Assignment, alloc: Allocator) void {
        switch (self) {
            .change => {},
            .problem => |message| alloc.free(message),
        }
    }
};

pub fn planAssignment(alloc: Allocator, word: []const u8) Allocator.Error!Assignment {
    const at = std.mem.findScalar(u8, word, '=') orelse
        return .{ .problem = try alloc.dupe(u8, "each setting is written key=value, such as fast_mode=on") };
    const key = settings_keys.currentPath(word[0..at]);
    const value = word[at + 1 ..];
    if (key.len == 0) return .{ .problem = try alloc.dupe(u8, "each setting is written key=value, such as fast_mode=on") };
    if (settings_keys.unknownPart(key)) |part| {
        return .{ .problem = settings_messages.formatUnknownPath(alloc, part) catch return error.OutOfMemory };
    }
    var write_problem: cli_config.WriteProblem = .none;
    const planned = cli_config.change(.{ .action = .set, .key = key, .value = value }, &write_problem) catch {
        return .{ .problem = cli_config.formatWriteProblem(alloc, key, value, write_problem, "/settings") catch return error.OutOfMemory };
    };
    return .{ .change = .{ .key = key, .value = value, .patch = planned.patch } };
}

pub fn handleSettings(app: anytype, rest: []const u8) !bool {
    const request = settingsRequest(rest) orelse return false;
    switch (request) {
        .help => try sayOwned(app, "", .neutral, try settingsHelp(app.alloc)),
        .assignments => |text| {
            var words = std.mem.tokenizeAny(u8, text, " \t");
            while (words.next()) |word| {
                const planned = try planAssignment(app.alloc, word);
                defer planned.deinit(app.alloc);
                switch (planned) {
                    .problem => |message| try say(app, "settings", .@"error", message),
                    .change => |change| try saveAssignment(app, change.key, change.value, change.patch),
                }
            }
        },
    }
    return true;
}

fn saveAssignment(app: anytype, key: []const u8, value: []const u8, patch: config_runtime.UserSettingsPatch) !void {
    var attempt = config_runtime.attemptUserPreferences(app.alloc, patch);
    defer attempt.deinit(app.alloc);
    switch (attempt) {
        .failure => |failure| try sayOwned(app, "settings", .@"error", try std.fmt.allocPrint(
            app.alloc,
            "Could not save {s}: {s}",
            .{ key, @errorName(failure.err) },
        )),
        .outcome => try sayOwned(app, "settings", .neutral, try std.fmt.allocPrint(
            app.alloc,
            "{s} = {f} saved to {s}; it applies the next time fx starts",
            .{ key, text_utils.terminalSafe(value), profile_paths.displayText("~/.fx/settings.json") },
        )),
    }
}

const NoticeRecorder = struct {
    alloc: Allocator,
    body: ?[]u8 = null,
    tone: types.NoticeTone = .neutral,

    pub noinline fn writeDomainNotice(self: *NoticeRecorder, notice: types.SemanticNotice, _: bool) !void {
        if (self.body) |old| self.alloc.free(old);
        self.body = try self.alloc.dupe(u8, notice.body);
        self.tone = notice.tone;
    }

    fn deinit(self: *NoticeRecorder) void {
        if (self.body) |old| self.alloc.free(old);
    }
};

test "/copy N takes a whole number from one up" {
    try std.testing.expectEqual(@as(?usize, 1), replyOrdinal(" 1 "));
    try std.testing.expectEqual(@as(?usize, 12), replyOrdinal("12"));
    try std.testing.expectEqual(@as(?usize, null), replyOrdinal("0"));
    try std.testing.expectEqual(@as(?usize, null), replyOrdinal("two"));
    try std.testing.expectEqual(@as(?usize, null), replyOrdinal("1 2"));
}

test "/copy N copies the N-th latest reply and says when there is none that far back" {
    const Clipboard = struct {
        copied: *?[]const u8,

        fn copy(self: @This(), text: []const u8) !bool {
            self.copied.* = text;
            return true;
        }
    };
    const Session = struct {
        replies: []const []const u8,

        pub fn nthAssistantReply(self: *const @This(), ordinal: usize) ?[]const u8 {
            if (ordinal == 0 or ordinal > self.replies.len) return null;
            return self.replies[self.replies.len - ordinal];
        }
    };
    const Agent = struct { session: Session };
    const CopyApp = struct {
        alloc: Allocator,
        recorder: NoticeRecorder,
        copied: ?[]const u8 = null,

        fn clipboard(self: *@This()) Clipboard {
            return .{ .copied = &self.copied };
        }

        pub noinline fn writeDomainNotice(self: *@This(), notice: types.SemanticNotice, visible: bool) !void {
            try self.recorder.writeDomainNotice(notice, visible);
        }
    };
    const alloc = std.testing.allocator;
    var agent: Agent = .{ .session = .{ .replies = &.{ "first", "second", "third" } } };
    var app: CopyApp = .{ .alloc = alloc, .recorder = .{ .alloc = alloc } };
    defer app.recorder.deinit();

    try copyNthReply(&app, &agent, "2");
    try std.testing.expectEqualStrings("second", app.copied.?);
    try std.testing.expectEqualStrings("Copied reply 2 back to clipboard.", app.recorder.body.?);

    app.copied = null;
    try copyNthReply(&app, &agent, "4");
    try std.testing.expect(app.copied == null);
    try std.testing.expectEqualStrings("There is no assistant reply 4 back to copy.", app.recorder.body.?);

    try copyNthReply(&app, &agent, "latest");
    try std.testing.expectEqualStrings(copy_usage, app.recorder.body.?);
    try std.testing.expectEqual(types.NoticeTone.@"error", app.recorder.tone);
}

test "/memory lists each instruction file with its size, and points at /init when none exist" {
    const alloc = std.testing.allocator;
    const some = try renderInstructionFiles(alloc, &.{
        .{ .path = "/home/u/.fx/AGENTS.md", .bytes = null },
        .{ .path = "/work/AGENTS.md", .bytes = 2048 },
    });
    defer alloc.free(some);
    try std.testing.expect(std.mem.startsWith(u8, some, "Instruction files fx reads at the start of a session:\n"));
    try std.testing.expect(std.mem.find(u8, some, "  /home/u/.fx/AGENTS.md (not present)\n") != null);
    try std.testing.expect(std.mem.find(u8, some, "  /work/AGENTS.md (2048 bytes)\n") != null);

    const none = try renderInstructionFiles(alloc, &.{.{ .path = "/work/AGENTS.md", .bytes = null }});
    defer alloc.free(none);
    try std.testing.expect(std.mem.startsWith(u8, none, "No instruction files yet. Run /init"));
}

test "/hooks lists each hook's event, matcher, command and timeout" {
    const alloc = std.testing.allocator;
    const empty = try renderHooks(alloc, &.{});
    defer alloc.free(empty);
    try std.testing.expect(std.mem.startsWith(u8, empty, "No hooks are configured."));

    const listed = try renderHooks(alloc, &.{
        .{ .event = .PreToolUse, .matcher = @constCast("Bash"), .command = @constCast("./check.sh"), .timeout_seconds = 5 },
        .{ .event = .Stop, .command = @constCast("notify-send done") },
    });
    defer alloc.free(listed);
    try std.testing.expectEqualStrings(
        "2 hooks registered for this session, by event:\nPreToolUse\n  [Bash] ./check.sh (timeout 5s)\nStop\n  notify-send done (timeout 30s)",
        listed,
    );
}

test "/hooks groups hooks by event, marks a blocking failure policy and an event fx never fires" {
    const alloc = std.testing.allocator;
    const listed = try renderHooks(alloc, &.{
        .{ .event = .PreToolUse, .matcher = @constCast("Bash"), .command = @constCast("./check.sh"), .timeout_seconds = 5, .on_failure = .block },
        .{ .event = .WorktreeCreate, .command = @constCast("./worktree.sh"), .timeout_seconds = 600 },
        .{ .event = .PreToolUse, .command = @constCast("./audit.sh"), .timeout_seconds = 600 },
        .{ .event = .Notification, .matcher = @constCast(""), .command = @constCast("notify-send fx"), .timeout_seconds = 600 },
    });
    defer alloc.free(listed);
    try std.testing.expectEqualStrings(
        "4 hooks registered for this session, by event:\n" ++
            "PreToolUse\n  [Bash] ./check.sh (timeout 5s, blocks when it fails)\n  ./audit.sh (timeout 600s)\n" ++
            "WorktreeCreate (fx never fires this event)\n  ./worktree.sh (timeout 600s)\n" ++
            "Notification\n  [] notify-send fx (timeout 600s)",
        listed,
    );

    const empty = try renderHooks(alloc, &.{});
    defer alloc.free(empty);
    try std.testing.expect(std.mem.find(u8, empty, "\"Notification\":[{\"matcher\":\"\"") != null);
    try std.testing.expect(std.mem.find(u8, empty, "/hooks") != null);
}

test "/settings tells key=value and --help apart from its older arguments" {
    try std.testing.expect(settingsRequest("") == null);
    try std.testing.expect(settingsRequest("startup-scrollback on") == null);
    try std.testing.expect(settingsRequest(" --help ").? == .help);
    try std.testing.expectEqualStrings("fast_mode=on theme=dark", settingsRequest(" fast_mode=on theme=dark ").?.assignments);
}

test "/settings --help lists the keys that key=value accepts" {
    const alloc = std.testing.allocator;
    const help = try settingsHelp(alloc);
    defer alloc.free(help);
    try std.testing.expect(std.mem.find(u8, help, "\n  fast_mode") != null);
    try std.testing.expect(std.mem.find(u8, help, "\n  status_line.context") != null);
    try std.testing.expect(std.mem.find(u8, help, "\n  theme") != null);
}

test "/settings key=value plans the same change as fx config set, and names what is wrong otherwise" {
    const alloc = std.testing.allocator;

    const good = try planAssignment(alloc, "fast_mode=on");
    defer good.deinit(alloc);
    try std.testing.expectEqualStrings("fast_mode", good.change.key);
    try std.testing.expectEqual(@as(?bool, true), good.change.patch.fast_mode);

    const bad_value = try planAssignment(alloc, "fast_mode=sometimes");
    defer bad_value.deinit(alloc);
    try std.testing.expectEqualStrings("invalid value for fast_mode: sometimes (use true or false)", bad_value.problem);

    const refused = try planAssignment(alloc, "model=some/model");
    defer refused.deinit(alloc);
    try std.testing.expectEqualStrings("can't change model with /settings; use /model in a session", refused.problem);

    const unknown = try planAssignment(alloc, "no_such_setting=1");
    defer unknown.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, unknown.problem, "unknown setting no_such_setting"));

    const malformed = try planAssignment(alloc, "=on");
    defer malformed.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, malformed.problem, "each setting is written key=value"));
}
