const std = @import("std");
const command_specs = @import("../slash_commands/command_specs.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const std_builtin = @import("builtin");
const command_admission = @import("../permissions/command_admission.zig");
const agent_runtime = @import("../agent/agent_runtime.zig");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const runtime_gateway_step = @import("../agent/runtime/gateway_step.zig");
const app_lifecycle = @import("../app/app_lifecycle.zig");
const app_mcp_runtime = @import("../app/app_mcp_runtime.zig");
const shared_theme = @import("../shared/theme.zig");
const ui_render = @import("../../ui/render.zig");
const app_runtime_setup = @import("../app/app_runtime_setup.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const secret = @import("../auth/secret.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const terminal_client_runtime = @import("../terminal/client.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const context_contract = @import("../workspace/context_contract.zig");
const workspace_diagnostics = @import("../workspace/diagnostics.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const provider_set = @import("../gateway/provider_set.zig");
const process_provider = @import("../execution/process_provider.zig");
const host = @import("../hosts/host.zig");
const pathing = @import("../workspace/pathing.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation = @import("../tooling/file_mutation.zig");
const gateway_error_format = @import("../shared/gateway_error_format.zig");
const open_work = @import("../todo/open_work.zig");
const http_pool = @import("../shared/http_pool.zig");
const gateway_client = @import("../../gateway/client.zig");
const image_attachments = @import("../images/image_attachments.zig");
const hooks = @import("../hooks/hooks.zig");
const heartbeat_hooks = @import("../hooks/heartbeat.zig");
const builtin_command_hooks = @import("../../builtins/hooks/command.zig");
const notification_sound = @import("../notifications/sound.zig");
const io_mod = @import("../shared/io.zig");
const select_watch = @import("../shared/select_watch.zig");
const shell_snapshot = @import("../terminal/shell_snapshot.zig");
const session_title_generation = @import("../session/session_title_generation.zig");
const compactor = @import("../compactor/compactor.zig");
const config_runtime = @import("../config/config_runtime.zig");
const terminal_env = @import("../shared/terminal_env.zig");
const cli_config = @import("cli_config.zig");
const claude_flags = @import("claude_flags.zig");
const plugin_manager = @import("../plugins/manager.zig");
const plugin_contributions = @import("../plugins/contributions.zig");
const agent_run_flags = @import("agent_run_flags.zig");
const flag_placement = @import("flag_placement.zig");
const print_stream = @import("print_stream.zig");
const build_options = @import("build_options");
const managed_contract = @import("../execution/managed_execution_contract.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const builtin_commands = @import("../../builtins/commands.zig");
const cli_flags = @import("cli_flags.zig");
const output_contracts = @import("../output/output_contracts.zig");
const mcp_elicitation_interaction = @import("../mcp/elicitation_interaction.zig");
const mcp_elicitation = @import("../mcp/elicitation.zig");
const mcp_access_policy = @import("../mcp/access_policy.zig");
const mcp_model_catalog = @import("../mcp/model_catalog.zig");
const mcp_host = @import("../mcp_host/host.zig");
const mcp_verbs = @import("../mcp_host/verbs.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const prompt_policy = @import("../config/prompt_policy.zig");
const auto_classifier_context = @import("../permissions/auto_classifier_context.zig");
const permission_gate = @import("../permissions/permission_gate.zig");
const permission_request = @import("../permissions/permission_request.zig");
const permissions = @import("../permissions/permissions.zig");
const session_runtime = @import("../session/session.zig");
const command_replay_store = @import("../session/command_replay_store.zig");
const session_codec = @import("../session/session_codec.zig");
const session_store = @import("../session/session_store.zig");
const session_adapter = @import("../session/session_adapter.zig");
const session_child_store = @import("../session/session_child_store.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const subagent_agent_adapter = @import("../subagent/agent_adapter.zig");
const subagent_authority = @import("../subagent/authority.zig");
const subagent_domain = @import("../subagent/domain.zig");
const subagent_execution = @import("../subagent/execution.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const subagent_reports = @import("../subagent/reports.zig");
const subagent_child_state = @import("../subagent/child_state.zig");
const subagent_model_contract = @import("../subagent/model_contract.zig");
const text_utils = @import("../shared/text_utils.zig");
const test_builtin_gateway = if (std_builtin.is_test)
    @import("../../builtins/gateway.zig")
else
    struct {};
const builtin_tools = @import("../../builtins/tools.zig");
const model_tool_schema = @import("../tooling/model_tool_schema.zig");
const tool_projection_mod = @import("../tooling/tool_projection.zig");
const tool_admission = @import("../tooling/tool_admission.zig");
const tool_args = @import("../tooling/tool_args.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const tool_presentation = @import("../tooling/tool_presentation.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const tool_runtime = @import("../tooling/tool_runtime.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const tool_specs = @import("../tooling/tool_specs.zig");
const web_fetch_runtime = @import("../tooling/web_fetch_runtime.zig");
const web_search_runtime = @import("../tooling/web_search_runtime.zig");
const types = @import("../shared/types.zig");
const history_range = @import("../shared/history_range.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const ask_presentation = @import("../../ui/ask_presentation.zig");
const url_opener = @import("../hosts/url_opener.zig");
const goal_state = @import("../goal/state.zig");
const goal_reminder = @import("../goal/reminder.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;
const ImageAttachment = types.ImageAttachment;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const SessionRuntime = session_runtime.SessionRuntime;
const ToolCall = types.ToolCall;
const ToolExecutionResult = agent_runtime.ToolExecutionResult;
const ToolPermissionDecision = types.ToolPermissionDecision;
const WorkerEvent = worker_runtime.WorkerEvent;
const WorkerRuntime = worker_runtime.WorkerRuntime;
const McpHasToolFn = tool_mcp_runtime.HasToolFn;

const supports_headless_interrupt = switch (std_builtin.target.os.tag) {
    .windows, .wasi, .freestanding => false,
    else => true,
};

const HeadlessInterruptInstallError = error{HeadlessInterruptBusy};
const headless_interrupt_exit_code: u8 = 130;
const headless_termination_exit_code: u8 = 143;
const headless_hangup_exit_code: u8 = 129;

const headless_interrupt = if (supports_headless_interrupt) struct {
    var coordinator_mutex: std.Io.Mutex = .init;
    var coordinator_active = false;
    var cancel_requested = std.atomic.Value(bool).init(false);
    var requested_signal = std.atomic.Value(u8).init(0);
    var test_after_reset_before_install: if (std_builtin.is_test) ?*const fn () void else void =
        if (std_builtin.is_test) null else {};
    var test_after_restore: if (std_builtin.is_test) ?*const fn () void else void =
        if (std_builtin.is_test) null else {};

    fn handle(signal: std.posix.SIG) callconv(.c) void {
        _ = requested_signal.cmpxchgStrong(
            0,
            @intCast(@backingInt(signal)),
            .seq_cst,
            .seq_cst,
        );
        cancel_requested.store(true, .seq_cst);
    }

    fn exitCode() u8 {
        return switch (@as(std.posix.SIG, @fromBackingInt(@intCast(requested_signal.load(.seq_cst))))) {
            std.posix.SIG.TERM => headless_termination_exit_code,
            std.posix.SIG.HUP => headless_hangup_exit_code,
            else => headless_interrupt_exit_code,
        };
    }

    fn acknowledge() void {
        cancel_requested.store(false, .seq_cst);
        requested_signal.store(0, .seq_cst);
    }

    const Scope = struct {
        old_sigint_action: std.posix.Sigaction = undefined,
        old_sigterm_action: std.posix.Sigaction = undefined,
        old_sighup_action: std.posix.Sigaction = undefined,
        installed: bool = false,

        fn install(enabled: bool) HeadlessInterruptInstallError!Scope {
            if (!enabled) return .{};
            coordinator_mutex.lockUncancelable(io_mod.getIo());
            defer coordinator_mutex.unlock(io_mod.getIo());
            if (coordinator_active) return error.HeadlessInterruptBusy;

            const action: std.posix.Sigaction = .{
                .handler = .{ .handler = handle },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            var scope = Scope{};
            requested_signal.store(0, .seq_cst);
            cancel_requested.store(false, .seq_cst);
            if (std_builtin.is_test) {
                if (test_after_reset_before_install) |hook| hook();
            }
            std.posix.sigaction(std.posix.SIG.INT, &action, &scope.old_sigint_action);
            std.posix.sigaction(std.posix.SIG.TERM, &action, &scope.old_sigterm_action);
            std.posix.sigaction(std.posix.SIG.HUP, &action, &scope.old_sighup_action);
            coordinator_active = true;
            scope.installed = true;
            return scope;
        }

        fn restore(self: *Scope, redeliver: bool) void {
            if (!self.installed) return;
            coordinator_mutex.lockUncancelable(io_mod.getIo());
            defer coordinator_mutex.unlock(io_mod.getIo());
            std.debug.assert(coordinator_active);
            std.posix.sigaction(std.posix.SIG.INT, &self.old_sigint_action, null);
            std.posix.sigaction(std.posix.SIG.TERM, &self.old_sigterm_action, null);
            std.posix.sigaction(std.posix.SIG.HUP, &self.old_sighup_action, null);
            if (std_builtin.is_test) {
                if (test_after_restore) |hook| hook();
            }
            if (redeliver and cancel_requested.load(.seq_cst)) {
                const signal: std.posix.SIG = @fromBackingInt(@intCast(requested_signal.load(.seq_cst)));
                _ = std.c.raise(signal);
            }
            coordinator_active = false;
            self.installed = false;
        }

        fn deinit(self: *Scope) void {
            self.restore(false);
        }

        fn restoreAndRedeliver(self: *Scope) void {
            self.restore(true);
        }

        fn requested(self: *const Scope) bool {
            return self.installed and cancel_requested.load(.seq_cst);
        }
    };
} else struct {
    fn exitCode() u8 {
        return headless_interrupt_exit_code;
    }

    fn acknowledge() void {}

    const Scope = struct {
        fn install(_: bool) HeadlessInterruptInstallError!Scope {
            return .{};
        }

        fn deinit(_: *Scope) void {}

        fn restoreAndRedeliver(_: *Scope) void {}

        fn requested(_: *const Scope) bool {
            return false;
        }
    };
};

pub const Config = struct {
    auth_mode: credentials.AuthMode = .local,
    command_usage: []const u8,
    default_model: []const u8,
    default_agent_step_limit: usize,
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
    gateway_models_path: []const u8,
    gateway_provider: gateway_provider.Provider,
    provider_set: provider_set.Set,
    process_provider: process_provider.Provider = process_provider.unavailable_provider,
    secret_store: host.SecretStore,
    prompt_policy: prompt_policy.Policy,
    skill_root_policy: skill_contract.RootPolicy,
    ignored_list_entries: []const []const u8,
    max_list_entries: usize,
    max_read_file_bytes: usize,
    max_read_file_lines: usize,
    max_read_file_line_len: usize,
    max_command_output_bytes: usize,
    max_tool_result_bytes: usize,
    max_history_turns: usize,
    mode_registry: mode_registry.Registry,
    load_mcp_host: ?mcp_host.LoadFn = null,
    context_limit_overrides: []const config_runtime.context_limits.Override = &.{},
    additional_directories: []const []const u8 = &.{},
    saved_directories_suppressed: bool = false,
};

fn runAskChild(
    raw: ?*anyopaque,
    turn: *subagent_execution.TurnContext,
    message: subagent_domain.QueuedMessage,
    admission: subagent_domain.AdmissionSnapshot,
    cancel: *std.atomic.Value(bool),
) subagent_execution.ServiceError!subagent_execution.RunOutcome {
    const ctx: *AskContext = @ptrCast(@alignCast(raw.?));
    var child_projection = ctx.cfg.mode_registry.buildModelToolProjection(
        ctx.alloc,
        ctx.deps.tool_set,
        ctx.mode_id,
        .{
            .permission_mode = admission.permission_mode,
            .permission_rules = admission.rules,
            .subagent_available = true,
            .run_code_surface = false,
        },
    ) catch return error.OutOfMemory;
    defer child_projection.deinit(ctx.alloc);
    return subagent_agent_adapter.run(.{
        .host = ctx.subagent_host orelse return error.ProviderFailed,
        .tool_context = ctx.toolContext(),
        .provider_set = ctx.cfg.provider_set,
        .system_prompt = ctx.cfg.prompt_policy.system_prompt,
        .model_prompt_overlay = ctx.cfg.prompt_policy.modelPromptOverlay(admission.model),
        .skill_catalog = .{ .skills = ctx.loaded_skills.skills, .diagnostics = ctx.loaded_skills.diagnostics },
        .advertised_tool_names = child_projection.advertised_names,
        .advertised_functions = child_projection.advertised_functions,
        .custom_tool_guidance = child_projection.custom_guidance,
        .context_registry = ctx.deps.context_registry,
        .context_enabled = ctx.context_enabled,
        .project_context = ctx.modelVisibleProjectContext(),
        .lifecycle_view = ctx.lifecycle_view,
    }, turn, message, admission, cancel);
}

pub const PromptRunResult = struct {
    exit_code: u8,
    assistant_output: []u8,
    final_output: []u8 = &.{},
    final_source: []u8 = &.{},
    interrupted: bool = false,
    output_write_failed: bool = false,
    output_reader_gone: bool = false,
    model: []u8 = &.{},
    session_id: []u8 = &.{},
    tool_calls: []ToolCallRecord = &.{},
    step_count: usize = 0,
    resolved_provider: []u8 = &.{},
    error_code: ?[]const u8 = null,
    auth_failure: ?auth_runtime.FailureSnapshot = null,
    recovery: ?types.RouteRecoveryStatus = null,
    usage: types.Usage = .{},
    blocked_by_limit: bool = false,

    pub fn deinit(self: PromptRunResult, alloc: Allocator) void {
        alloc.free(self.assistant_output);
        if (self.final_output.len > 0) alloc.free(self.final_output);
        if (self.final_source.len > 0) alloc.free(self.final_source);
        if (self.model.len > 0) alloc.free(self.model);
        if (self.resolved_provider.len > 0) alloc.free(self.resolved_provider);
        if (self.session_id.len > 0) alloc.free(self.session_id);
        freeToolCallRecords(alloc, self.tool_calls);
    }
};

inline fn failPromptRunResult(err: anytype) @TypeOf(err)!PromptRunResult {
    return @errorCast(failPromptRunResultDynamic(err));
}

noinline fn failPromptRunResultDynamic(err: anyerror) anyerror!PromptRunResult {
    return err;
}

test "prompt result failure writer preserves exact error type and identity" {
    const failure = failPromptRunResult(error.ImageIdOverflow);
    try std.testing.expect(@TypeOf(failure) == error{ImageIdOverflow}!PromptRunResult);
    try std.testing.expectError(error.ImageIdOverflow, failure);
}

const ResumeTarget = session_store.ResumeTarget;

const AskOptions = struct {
    prompt: []u8,
    resume_target: ?ResumeTarget = null,
    agent: agent_run_flags.Overrides = .{},
    image_paths: std.ArrayList([]u8) = .empty,
    images: std.ArrayList(ImageAttachment) = .empty,
    system_prompt_override: ?[]u8 = null,
    system_prompt_append: ?[]u8 = null,
    settings_arena: ?std.heap.ArenaAllocator = null,
    json_output: bool = false,
    output_format: ?print_stream.OutputFormat = null,
    prompt_permissions: bool = false,
    bare: bool = false,
    allowed_tools: std.ArrayList([]u8) = .empty,
    tools: ?[]u8 = null,
    disallowed_tools: std.ArrayList([]u8) = .empty,
    session_name: ?[]u8 = null,
    timeout_ms: ?usize = null,
    quiet: bool = false,
    no_save: bool = false,
    no_color: bool = false,
    settings_overrides: std.ArrayList(config_runtime.SettingOverride) = .empty,

    fn deinit(self: *AskOptions, alloc: Allocator) void {
        self.settings_overrides.deinit(alloc);
        alloc.free(self.prompt);
        for (self.image_paths.items) |p| alloc.free(p);
        self.image_paths.deinit(alloc);
        for (self.allowed_tools.items) |list| alloc.free(list);
        self.allowed_tools.deinit(alloc);
        if (self.tools) |list| alloc.free(list);
        for (self.disallowed_tools.items) |list| alloc.free(list);
        self.disallowed_tools.deinit(alloc);
        if (self.session_name) |name| alloc.free(name);
        for (self.images.items) |image| types.freeImageAttachment(alloc, image);
        self.images.deinit(alloc);
        if (self.system_prompt_override) |s| alloc.free(s);
        if (self.system_prompt_append) |appended| alloc.free(appended);
        if (self.settings_arena) |*arena| arena.deinit();
        self.agent.deinit(alloc);
    }
};

const ToolCallRecord = struct {
    name: []u8,
    status: []u8,
    error_category: ?workspace_diagnostics.ToolCallOutcome = null,
    error_code: ?[]u8 = null,
    command_result_json: ?[]u8 = null,
    ask_question_text: ?[]u8 = null,
    web_search_completion: ?types.WebSearchCompletion = null,
    web_fetch_completion: ?types.WebFetchCompletion = null,
};

const PendingToolProgress = struct {
    call_id: []u8,
    tool_name: []u8,
    text: ?[]u8 = null,
    visible: bool = false,

    fn deinit(self: PendingToolProgress, alloc: Allocator) void {
        alloc.free(self.call_id);
        alloc.free(self.tool_name);
        if (self.text) |text| alloc.free(text);
    }
};

fn postAskReport(
    raw: ?*anyopaque,
    _: *subagent_tool_host.Runtime,
    delivery: subagent_tool_host.Delivery,
) subagent_tool_host.PostReportError!void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw.?));
    const alloc = std.heap.c_allocator;
    const text = switch (delivery) {
        .report => |report| try subagent_reports.message(alloc, report, ctx.max_tool_result_bytes),

        .message => |message| try subagent_reports.messageText(alloc, message.agent, message.child_id, message.text, ctx.max_tool_result_bytes, null),
    };
    ctx.worker.postMail(alloc, .{
        .prompt = text,
        .images = &.{},
        .model = &.{},
        .api_key = &.{},
        .permission_mode = ctx.permission_mode,
        .history = &.{},
        .grants = &.{},
        .author = .child,
        .mail = if (delivery == .report) .report else .message,
    }) catch |err| {
        alloc.free(text);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.QueueFull => error.QueueFull,
            else => error.AgentGone,
        };
    };
}

fn postAskTaskNotice(raw: ?*anyopaque, _: ?*anyopaque, text: []const u8) bool {
    const ctx: *AskContext = @ptrCast(@alignCast(raw orelse return false));
    const alloc = std.heap.c_allocator;
    const owned = alloc.dupe(u8, text) catch return false;
    ctx.worker.postMail(alloc, .{
        .prompt = owned,
        .images = &.{},
        .model = &.{},
        .api_key = &.{},
        .permission_mode = ctx.permission_mode,
        .history = &.{},
        .grants = &.{},
        .author = .child,
        .mail = .report,
    }) catch |err| {
        alloc.free(owned);
        debug_trace.logf("mailbox", "ask task notice not queued err={s}", .{@errorName(err)});
        return false;
    };
    return true;
}

fn askPendingMail(raw: ?*anyopaque, _: ?*anyopaque) usize {
    const ctx: *AskContext = @ptrCast(@alignCast(raw orelse return 0));
    return ctx.worker.queuedPromptCount();
}

fn askBackgroundWorkLive(raw: *anyopaque) bool {
    const ctx: *AskContext = @ptrCast(@alignCast(raw));
    return ctx.managed_executions.hasDeadlinedLiveTasks();
}

fn freeToolCallRecord(alloc: Allocator, record: ToolCallRecord) void {
    alloc.free(record.name);
    alloc.free(record.status);
    if (record.error_code) |code| alloc.free(code);
    if (record.command_result_json) |json| alloc.free(json);
    if (record.ask_question_text) |text| alloc.free(text);
}

fn freeToolCallRecords(alloc: Allocator, records: []ToolCallRecord) void {
    for (records) |record| freeToolCallRecord(alloc, record);
    if (records.len > 0) alloc.free(records);
}

const WriteFn = *const fn (?*anyopaque, []const u8) anyerror!void;
const PermissionApprovalPromptResult = enum {
    approve,
    deny,
    unavailable,
};
const NotifyAttentionFn = *const fn (?*anyopaque) void;
const PermissionApprovalPromptFn = *const fn (?*anyopaque, ?*anyopaque, WriteFn, []const u8, ?*anyopaque, NotifyAttentionFn) anyerror!PermissionApprovalPromptResult;
const IsTtyFn = *const fn (?*anyopaque) bool;
const LoadStartupStateFn = *const fn (Allocator, oauth_transport.Provider, host.SecretStore, []const u8, usize, ?model_provider.ProviderId, ?[]const u8, []const config_runtime.SettingOverride) anyerror!app_lifecycle.StartupState;
const LoadStartupStateWithAuthModeFn = *const fn (Allocator, oauth_transport.Provider, host.SecretStore, []const u8, usize, credentials.AuthMode, ?model_provider.ProviderId, ?[]const u8, []const config_runtime.SettingOverride) anyerror!app_lifecycle.StartupState;
const InitializeSessionStoresFn = *const fn (*AskContext) anyerror!void;
const LoadSkillsFn = *const fn (
    Allocator,
    []const u8,
    skill_contract.RootPolicy,
) app_runtime_setup.LoadSkillsError!app_runtime_setup.LoadedSkills;
const ProcessQueuedPromptFn = *const fn (*agent_runtime.Agent, *const agent_runtime.AgentRuntimeDeps, ?agent_runtime.SemanticPresentationSink, agent_runtime.LifecycleContext, agent_runtime.Config, worker_runtime.QueuedPrompt) anyerror!void;
const PersistYoloAcknowledgmentFn = *const fn (Allocator) config_runtime.CommitAttempt;

const RunDeps = struct {
    stdin_ctx: ?*anyopaque = null,
    stdout_ctx: ?*anyopaque = null,
    stderr_ctx: ?*anyopaque = null,
    permission_approval_prompt_ctx: ?*anyopaque = null,
    write_stdout: WriteFn = writeRealStdout,
    write_stderr: WriteFn = writeRealStderr,
    permission_approval_prompt: PermissionApprovalPromptFn = promptRealPermissionApproval,
    stdin_is_tty: IsTtyFn = realStdinIsTty,
    stdout_is_tty: IsTtyFn = realStdoutIsTty,
    stderr_is_tty: IsTtyFn = realStderrIsTty,
    load_startup_state: LoadStartupStateFn = loadStartupStateDefault,
    load_startup_state_with_auth_mode: LoadStartupStateWithAuthModeFn = app_lifecycle.loadStartupStateForRunWithOverrides,
    initialize_session_stores: InitializeSessionStoresFn = initializeSessionStoresDefault,
    load_skills: LoadSkillsFn = app_runtime_setup.loadSkills,
    context_registry: context_contract.Registry,
    tool_set: tool_set_contract.ToolSet,
    notify_user_enabled: bool = false,
    sensitive_file_guard: bool = true,
    workspace_in_git_work_tree: bool = false,
    load_mcp_host: ?mcp_host.LoadFn = null,
    process_queued_prompt: ProcessQueuedPromptFn = processQueuedPromptDefault,
    persist_yolo_acknowledgment: PersistYoloAcknowledgmentFn = persistYoloAcknowledgmentDefault,
    install_headless_interrupt: bool = false,
    stdin_source: StdinSource = .real,
    invocation: Invocation = .ask_command,
    output_format_env: OutputFormatEnvFn = realOutputFormatEnv,
};

const OutputFormatEnvFn = *const fn () [2]print_stream.EnvDefault;

fn realOutputFormatEnv() [2]print_stream.EnvDefault {
    return .{
        .{ .name = "FX_OUTPUT_FORMAT", .value = io_mod.getenv("FX_OUTPUT_FORMAT") },
        .{ .name = "KIMI_MODEL_OUTPUT_FORMAT", .value = io_mod.getenv("KIMI_MODEL_OUTPUT_FORMAT") },
    };
}

const OutputMode = enum {
    quiet,
    json,
    raw,
    terminal,
    terminal_no_color,

    fn isTerminal(self: OutputMode) bool {
        return self == .terminal or self == .terminal_no_color;
    }

    fn capturesJson(self: OutputMode) bool {
        return self == .json;
    }
};

const RunOptions = struct {
    output_mode: OutputMode,
    stream_json: bool = false,
    prompt_permissions: bool = false,
    bare: bool = false,
    allowed_tools: []const []const u8 = &.{},
    tools: ?[]const u8 = null,
    disallowed_tools: []const []const u8 = &.{},
    images: []const ImageAttachment = &.{},
    command_timeout_ms: ?usize = null,
    save_session: bool = true,
    session_name: ?[]const u8 = null,
    resume_target: ?ResumeTarget = null,
    color_enabled: bool = true,
    provider_override: ?model_provider.ProviderId = null,
    model_override: ?[]const u8 = null,
    settings_overrides: []const config_runtime.SettingOverride = &.{},
    effort_override: ?types.ReasoningEffort = null,
    fast_override: ?bool = null,
    ultrafast_override: ?bool = null,
    provider_order_override: ?[]const []const u8 = null,
    provider_strict_override: ?bool = null,
    deps: RunDeps,
};

fn buildAskGatewayToolProjection(
    alloc: Allocator,
    registry: mode_registry.Registry,
    tool_set: tool_set_contract.ToolSet,
    mode_id: []const u8,
    options: tool_projection_mod.Options,
    has_child_capability: bool,
) !tool_projection_mod.EffectiveToolProjection {
    if (has_child_capability) {
        return registry.buildModelToolProjection(
            alloc,
            tool_set,
            mode_id,
            options,
        );
    }

    const shell_index = for (tool_set.registry.tools, 0..) |tool, index| {
        if (tool.executor_kind == .terminal and
            std.mem.eql(u8, tool.name, "Bash"))
        {
            break index;
        }
    } else {
        return registry.buildModelToolProjection(
            alloc,
            tool_set,
            mode_id,
            options,
        );
    };

    const projected_tools = try alloc.dupe(
        tool_dispatch.Tool,
        tool_set.registry.tools,
    );
    defer alloc.free(projected_tools);
    projected_tools[shell_index] = builtin_tools.shell;
    return registry.buildModelToolProjection(
        alloc,
        .{
            .registry = .{ .tools = projected_tools },
            .order = tool_set.order,
            .read_only_tool_names = tool_set.read_only_tool_names,
        },
        mode_id,
        options,
    );
}

const StdinSource = union(enum) {
    real,
    tty,
    bytes: []const u8,
    read_error,
};

const stdin_prompt_resource_byte_limit: usize = 8 * 1024 * 1024;

const AskContext = struct {
    alloc: Allocator,
    cfg: Config,
    deps: RunDeps,
    workspace_root: []const u8,
    workspace_access: workspace_access.WorkspaceAccess = .{},
    api_key: []const u8 = "",
    gateway_team: ?[]const u8 = null,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]const u8 = null,
    refreshed_credential: ?credentials.Credential = null,
    provider: model_provider.ProviderId = .gateway,
    model_catalog_access: credentials.CatalogAccess = .{ .public_only = .no_credential },
    model: []const u8 = "",
    reviewer_model: []const u8 = "",
    goal: goal_state.State = .{},
    agent_step_limit: usize = 0,
    max_tool_result_bytes: usize = 64 * 1024,
    auto_compact_percent: u8 = compactor.default_percent,
    context_limits: config_runtime.context_limits.Values = .{},
    fast_mode: bool = false,
    persisted_ultrafast_mode: bool = false,
    ultrafast_mode: bool = false,
    effort: types.ReasoningEffort = .auto,
    provider_order: []const []const u8 = &.{},
    provider_strict: bool = false,
    resolved_provider: ?[]u8 = null,
    first_call_tool_choice: types.ToolChoice = .auto,
    permission_mode: PermissionMode = .ask,
    permission_rules: types.PermissionRuleSet = .{},
    mode_id: []const u8,
    auto_classifier: permission_auto_classifier.Classifier =
        permission_auto_classifier.Classifier.disabled(),
    worker: WorkerRuntime = .{},
    use_process_interrupt_flag: bool = false,
    terminal_client: terminal_client_runtime.Runtime = .{},
    managed_executions: managed_execution.Runtime,
    ephemeral_command_replay: command_replay_store.EphemeralStore,
    subagent_host: ?*subagent_tool_host.Runtime = null,
    loaded_skills: app_runtime_setup.LoadedSkills = .{},
    v2_store: ?session_adapter.Store = null,
    v2: ?*session_adapter.Session = null,
    v2_children: ?*subagent_child_state.V2Children = null,
    v2_preferences: ?session_codec.DurableSessionPreferences = null,
    session_write_mutex: std.Io.Mutex = .init,
    requested_resume: ?ResumeTarget = null,
    seed_model: []const u8 = "",
    command_timeout_ms: ?usize = null,
    session: SessionRuntime,
    skills_dir: []u8 = &.{},
    context_snapshot: context_contract.GatheredContextSnapshot = .{},
    context_enabled: bool = true,
    mcp_host: ?*mcp_host.Host = null,
    mcp_elicitation_capabilities: @import("../mcp/elicitation.zig").Capabilities = .{},
    failed: bool = false,
    open_work_reminder: open_work.Reminder = .{},
    blocked_by_limit: bool = false,
    output_write_failed: bool = false,
    output_reader_gone: bool = false,
    typed_error_code: ?[]const u8 = null,
    auth_failure: ?auth_runtime.FailureSnapshot = null,
    output_mode: OutputMode = .raw,
    print_stream: ?print_stream.Stream = null,
    print_stream_mutex: std.Io.Mutex = .init,
    thinking_block: print_stream.ThinkingBlock = .{},
    prompt_permissions: bool = false,
    presenter: ?*ask_presentation.Runtime = null,
    pending_tool_progress: std.ArrayList(PendingToolProgress) = .empty,
    deferred_tool_progress: std.ArrayList([]u8) = .empty,
    pending_tool_progress_mutex: std.Io.Mutex = .init,
    raw_boundary_pending: bool = false,
    response_output_start: usize = 0,
    response_restart_pending: bool = false,
    raw_trailing_newlines: u8 = 0,
    raw_has_output: bool = false,
    command_output_line_open: bool = false,
    assistant_output: std.ArrayList(u8) = .empty,
    final_output: std.ArrayList(u8) = .empty,
    final_source: std.ArrayList(u8) = .empty,
    tool_call_records: std.ArrayList(ToolCallRecord) = .empty,
    tool_call_records_mutex: std.Io.Mutex = .init,
    web_search_progress_mutex: std.Io.Mutex = .init,
    step_count: usize = 0,
    web_fetch_runtime: web_fetch_runtime.Runtime = web_fetch_runtime.Runtime.init(.{}),
    web_search_runtime: web_search_runtime.Runtime,
    capability_resolver: gateway_provider.CapabilityResolver = .{},
    lifecycle_runtime: hooks.Runtime,
    lifecycle_view: hooks.RuntimeView,
    command_hooks: builtin_command_hooks.State = .{},
    session_title: session_title_generation.TitleSlot = .{},
    session_name: ?[]const u8 = null,
    session_heartbeat: ?heartbeat_hooks.Heartbeat = null,
    session_ended: bool = false,
    session_started: bool = false,
    active_turn_id: u64 = 0,
    notification_player: ?notification_sound.Player = null,
    image_snapshot_temp_dir: ?[]u8 = null,
    prompt_snapshot_committed: bool = false,
    last_recovery_status: ?types.RouteRecoveryStatus = null,
    last_recovery_notice_kind: ?types.RouteRecoveryStatus.Kind = null,

    fn init(alloc: Allocator, cfg: Config, deps: RunDeps, workspace_root: []const u8) AskContext {
        const lifecycle_runtime = hooks.Runtime.init(alloc);
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .deps = deps,
            .workspace_root = workspace_root,
            .model = cfg.default_model,
            .seed_model = cfg.default_model,
            .mode_id = cfg.mode_registry.default_mode_id,
            .session = session_runtime.SessionRuntime.init(cfg.max_history_turns),
            .web_search_runtime = web_search_runtime.Runtime.init(.{
                .provider = cfg.provider_set.gateway.fx_search.?,
            }),
            .terminal_client = terminal_client_runtime.Runtime.init(
                cfg.process_provider,
            ),
            .managed_executions = managed_execution.Runtime.init(alloc),
            .ephemeral_command_replay = command_replay_store.EphemeralStore.init(alloc),
            .lifecycle_runtime = lifecycle_runtime,
            .lifecycle_view = hooks.RuntimeView.empty(),
        };
    }

    fn configureNotifications(
        self: *AskContext,
        turn_end: bool,
        attention_required: bool,
    ) !void {
        self.notification_player = notification_sound.Player.init(.{
            .ctx = self,
            .emit = emitAskNotificationBell,
        });
        try self.lifecycle_runtime.registerPostTurnEnd(.{
            .name = "fx.ask.limit",
            .ctx = self,
            .run = noteLimitEndedTurn,
        });
        if (turn_end) {
            try self.lifecycle_runtime.registerPostTurnEnd(.{
                .name = "fx.sound.turn_end",
                .ctx = self,
                .run = postTurnEndNotification,
            });
        }
        if (attention_required) {
            try self.lifecycle_runtime.registerAttentionRequired(.{
                .name = "fx.sound.attention_required",
                .ctx = self,
                .run = attentionRequiredNotification,
            });
        }
        try builtin_command_hooks.Runtime(AskContext).configure(self);
        try self.lifecycle_runtime.registerStop(.{
            .name = "fx.todo.open_work",
            .ctx = self,
            .run = openWorkStop,
            .applies = openWorkApplies,
        });
        self.lifecycle_view = self.lifecycle_runtime.freeze();
        self.managed_executions.setTaskHook(.{ .view = self.lifecycle_view, .scope = self.hookScope() });
        self.managed_executions.setNoticeSink(.{ .context = self, .post_fn = postAskTaskNotice, .pending_fn = askPendingMail });
    }

    fn hookScope(self: *const AskContext) hooks.Scope {
        return .{ .kind = .ask, .workspace_root = self.workspace_root };
    }

    fn startSessionLifecycle(self: *AskContext) !void {
        if (self.session_ended or self.session_started) return;
        self.session_started = true;
        const definitions = self.command_hooks.definitions orelse return;
        const source: hooks.external.SessionSource = if (self.requested_resume != null) .@"resume" else .startup;
        if (source == .@"resume") self.adoptStoredSessionTitle();
        builtin_command_hooks.Runtime(AskContext).openSession(self, self.hookScope(), .{
            .session_id = self.activeSessionId(),
            .session_title = self.session_title.get(),
            .source = source,
            .model = self.seed_model,
        });
        if (hooks.external.sessionHeartbeatEnabled(definitions)) {
            self.session_heartbeat = try heartbeat_hooks.Heartbeat.start(self.alloc, self, tickSessionHeartbeat);
        }
    }

    fn adoptStoredSessionTitle(self: *AskContext) void {
        const v2 = self.v2 orelse return;
        const info = v2.info(self.alloc) catch return;
        const title = info.title orelse return;
        defer self.alloc.free(title);
        self.session_title.set(self.alloc, title) catch {};
    }

    fn tickSessionHeartbeat(raw: *anyopaque, uptime_ms: i64) void {
        const self: *AskContext = @ptrCast(@alignCast(raw));
        builtin_command_hooks.Runtime(AskContext).fire(self, .SessionHeartbeat, "", self.hookScope(), &.{
            .{ .key = hooks.external.uptime_key, .value = .{ .integer = uptime_ms } },
        }, null);
    }

    fn endSessionLifecycle(self: *AskContext) void {
        if (self.session_ended) return;
        self.session_ended = true;
        if (self.session_heartbeat) |*heartbeat| {
            heartbeat.stop(self.alloc);
            self.session_heartbeat = null;
        }
        if (!self.session_started or self.command_hooks.definitions == null) return;
        builtin_command_hooks.Runtime(AskContext).closeSession(self, self.hookScope(), .exit);
    }

    fn dispatchAttentionRequired(self: *AskContext, kind: hooks.AttentionKind) void {
        agent_runtime.dispatchAttentionRequiredCheckpoint(self.lifecycleContext(), .{
            .turn_id = self.active_turn_id,
            .kind = kind,
        });
    }

    fn noteLimitEndedTurn(
        raw: *anyopaque,
        input: hooks.PostTurnEndInput,
    ) hooks.HandlerError!void {
        const self: *AskContext = @ptrCast(@alignCast(raw));
        if (input.invocation.scope.kind != .ask) return;
        const name = input.error_name orelse return;
        if (!std.mem.eql(u8, name, gateway_error_format.limit_failure_name)) return;
        self.blocked_by_limit = true;
        self.writeStderr("fx ask: " ++ gateway_error_format.limit_blocked_notice ++ "\n") catch {};
    }

    fn postTurnEndNotification(
        raw: *anyopaque,
        input: hooks.PostTurnEndInput,
    ) hooks.HandlerError!void {
        const self: *AskContext = @ptrCast(@alignCast(raw));
        if (input.invocation.scope.kind != .ask) return;
        const cue: notification_sound.Cue = switch (input.outcome) {
            .completed => .success,
            .failed => .@"error",
            .interrupted, .paused => return,
        };
        self.playNotification(.turn_end, cue);
    }

    fn openWorkApplies(raw: *anyopaque, invocation: hooks.Invocation) bool {
        const self: *AskContext = @ptrCast(@alignCast(raw));
        if (invocation.scope.kind != .ask) return false;
        const turn_id = invocation.turn_id orelse return false;
        const todo = &self.session.agent.todo;
        return todo.seeded and self.open_work_reminder.owedFor(turn_id, todo.items);
    }

    fn openWorkStop(raw: *anyopaque, input: hooks.StopInput) hooks.HandlerError!hooks.StopAction {
        const self: *AskContext = @ptrCast(@alignCast(raw));
        if (!input.can_continue or input.invocation.scope.kind != .ask) return .allow;
        const turn_id = input.invocation.turn_id orelse return .allow;
        const todo = &self.session.agent.todo;
        if (!todo.seeded) return .allow;
        const text = self.open_work_reminder.forTurn(turn_id, todo.items) orelse return .allow;
        return .{ .continue_once = text };
    }

    fn attentionRequiredNotification(
        raw: *anyopaque,
        input: hooks.AttentionRequiredInput,
    ) hooks.HandlerError!void {
        const self: *AskContext = @ptrCast(@alignCast(raw));
        if (input.invocation.scope.kind != .ask) return;
        self.playNotification(.attention_required, .success);
    }

    fn playNotification(
        self: *AskContext,
        kind: notification_sound.Kind,
        cue: notification_sound.Cue,
    ) void {
        const player = if (self.notification_player) |*configured|
            configured
        else {
            debug_trace.logf(
                "notifications",
                "notification delivery dropped kind={s} reason=player_not_configured",
                .{@tagName(kind)},
            );
            return;
        };
        debug_trace.logf("notifications", "sound play kind={s} cue={s}", .{ @tagName(kind), @tagName(cue) });
        switch (kind) {
            .attention_required => player.playAttention(cue),
            .turn_end => player.play(cue),
        }
    }

    fn goalView(self: *AskContext) ?goal_state.View {
        const now_ms = io_mod.milliTimestamp();
        if (self.goal.snapshot(now_ms) == null) return null;
        return .{ .state = &self.goal, .alloc = self.alloc, .now_ms = now_ms };
    }

    fn deinit(self: *AskContext) void {
        self.goal.deinit(self.alloc);
        self.terminal_client.closeOwnedTerminals();
        if (self.subagent_host) |subagent_host| subagent_host.deinit();
        self.subagent_host = null;
        if (self.v2_children) |children| {
            children.deinit();
            self.alloc.destroy(children);
        }
        self.v2_children = null;
        self.managed_executions.setNoticeSink(null);
        self.managed_executions.terminateForProcessExit();
        self.managed_executions.deinit();
        self.terminal_client.deinit();
        self.workspace_access.deinit(self.alloc);
        self.worker.deinit(std.heap.c_allocator);
        self.web_fetch_runtime.deinit(self.alloc);
        self.web_search_runtime.deinit();
        if (self.refreshed_credential) |*credential| credential.deinit(self.alloc);
        self.endSessionLifecycle();
        self.capability_resolver.deinit(self.alloc);
        self.command_hooks.deinit(self.alloc);
        self.session_title.deinit(self.alloc);
        self.lifecycle_runtime.deinit();
        if (self.v2) |v2| v2.close();
        self.v2 = null;
        if (self.v2_store) |*store| store.deinit(self.alloc);
        self.v2_store = null;
        if (self.v2_preferences) |*preferences| preferences.deinit(self.alloc);
        self.v2_preferences = null;
        self.ephemeral_command_replay.deinit();
        self.permission_rules.deinit(self.alloc);
        self.session.deinit(self.alloc);
        if (self.skills_dir.len > 0) self.alloc.free(self.skills_dir);
        self.context_snapshot.deinit(self.alloc);

        if (self.mcp_host != null) mcp_host.signalServersForExit();
        if (self.image_snapshot_temp_dir) |path| {
            image_attachments.cleanupSnapshotDir(path);
            self.alloc.free(path);
        }
        if (self.print_stream) |*stream| stream.deinit();
        self.assistant_output.deinit(self.alloc);
        self.final_output.deinit(self.alloc);
        self.final_source.deinit(self.alloc);
        for (self.pending_tool_progress.items) |progress| progress.deinit(self.alloc);
        self.pending_tool_progress.deinit(self.alloc);
        for (self.deferred_tool_progress.items) |progress| self.alloc.free(progress);
        self.deferred_tool_progress.deinit(self.alloc);
        for (self.tool_call_records.items) |record| {
            freeToolCallRecord(self.alloc, record);
        }
        self.tool_call_records.deinit(self.alloc);
        if (self.resolved_provider) |provider| self.alloc.free(provider);
        self.loaded_skills.deinit(self.alloc);
    }

    fn lifecycleContext(self: *AskContext) agent_runtime.LifecycleContext {
        return .{
            .view = self.lifecycle_view,
            .scope = .{
                .kind = .ask,
                .workspace_root = self.workspace_root,
                .session_id = self.activeSessionId(),
            },
            .outcome_allocator = self.alloc,
        };
    }

    fn cancelFlag(self: *AskContext) *std.atomic.Value(bool) {
        if (comptime supports_headless_interrupt) {
            if (self.use_process_interrupt_flag) {
                return &headless_interrupt.cancel_requested;
            }
        }
        return &self.worker.worker_cancel_requested;
    }

    fn checkCancellation(self: *AskContext) !void {
        if (self.cancelFlag().load(.seq_cst)) return error.Cancelled;
    }

    fn processInterruptRequested(self: *const AskContext) bool {
        if (comptime supports_headless_interrupt) {
            return self.use_process_interrupt_flag and
                headless_interrupt.cancel_requested.load(.seq_cst);
        }
        return false;
    }

    fn activeSessionId(self: *const AskContext) ?[]const u8 {
        return if (self.v2) |v2| v2.id() else null;
    }

    fn sessionChildCapability(self: *AskContext) ?*session_child_store.SessionChildCapability {
        const v2 = self.v2 orelse return null;
        return v2.childCapability() catch |err| {
            debug_trace.logf("session", "event=sessions_v2_side_files_unavailable session={s} err={s}", .{ v2.id(), @errorName(err) });
            return null;
        };
    }

    fn imageSnapshotStorageDir(self: *AskContext) ![]u8 {
        return session_store.imageSnapshotTempDir(self.alloc, &self.image_snapshot_temp_dir);
    }

    fn captureImageAttachment(self: *AskContext, attachment: *ImageAttachment) !void {
        const snapshot_dir = try self.imageSnapshotStorageDir();
        defer self.alloc.free(snapshot_dir);
        try image_attachments.captureImageSnapshotWithBudget(
            self.alloc,
            attachment,
            snapshot_dir,
            .{ .cancel_flag = self.cancelFlag() },
        );
        if (self.v2 != null) try image_attachments.inlineCapturedSnapshot(self.alloc, attachment);
    }

    fn captureImageAttachments(self: *AskContext, attachments: []ImageAttachment) !void {
        const snapshot_dir = try self.imageSnapshotStorageDir();
        defer self.alloc.free(snapshot_dir);
        try image_attachments.captureImageSnapshots(
            self.alloc,
            attachments,
            snapshot_dir,
            .{ .cancel_flag = self.cancelFlag() },
        );
        if (self.v2 != null) try image_attachments.inlineCapturedSnapshots(self.alloc, attachments);
    }

    fn updateStaleShellHandles(self: *AskContext, history: []const session_runtime.HistoryTurn) void {
        self.session.has_stale_shell_handles = session_runtime.detectStaleShellHandles(
            self.alloc,
            history,
            &self.managed_executions,
        ) catch |err| blk: {
            debug_trace.logf(
                "session",
                "event=stale_shell_handle_scan outcome=skipped err={s}",
                .{@errorName(err)},
            );
            break :blk false;
        };
    }

    fn initializeSessionStores(self: *AskContext) !void {
        self.v2_store = session_adapter.Store.openFromEnv(self.alloc) catch |err| {
            if (err == error.OutOfMemory or self.requested_resume != null) return err;
            debug_trace.logf("session", "event=ask_session_store_unavailable backend=v2 error={s}", .{@errorName(err)});
            try self.writeStderr("fx ask: warning: session persistence unavailable; error=");
            try self.writeStderr(@errorName(err));
            try self.writeStderr("; continuing without saving\n");
            return;
        };
        errdefer {
            self.v2_store.?.deinit(self.alloc);
            self.v2_store = null;
        }
        const store = &self.v2_store.?;
        const seed_preferences = session_codec.DurableSessionPreferences{
            .provider = self.provider,
            .model = @constCast(self.seed_model),
            .effort = self.effort,
            .fast_mode = self.fast_mode,
            .ultrafast_mode = self.persisted_ultrafast_mode,
        };

        store.notice = .{ .context = self, .emit = conversionNotice };
        const v2 = if (self.requested_resume) |target|
            session_adapter.Session.resumeSession(self.alloc, store, switch (target) {
                .last => .last,
                .id => |id| .{ .id = id },
            }, self.workspace_root, .ask) catch |err| {
                if (store.conversionProblem()) |problem| {
                    self.writeStderr("fx ask: the session can't be converted: ") catch {};
                    self.writeLine(problem) catch {};
                }
                return err;
            }
        else blk: {
            var permission_state = try self.session.snapshotPermissionState(self.alloc);
            defer permission_state.deinit(self.alloc);
            break :blk try session_adapter.Session.create(self.alloc, store, self.workspace_root, .ask, .{
                .preferences = seed_preferences,
                .language = self.session.languageSnapshot(),
                .permission_state = permission_state,
            });
        };
        errdefer v2.close();
        try v2.nameSession(self.session_name);

        if (self.requested_resume != null) {
            var restored = try v2.restore(self.alloc);
            defer restored.deinit(self.alloc);
            try self.session.restoreWithPermissionState(
                self.alloc,
                restored.language,
                restored.history,
                restored.permission_state orelse .{},
            );
            self.session.agent.todo.restoreJson(restored.todos);
            updateStaleShellHandles(self, restored.history);
            if (restored.preferences) |preferences| {
                self.v2_preferences = preferences;
                restored.preferences = null;
                self.provider = preferences.provider;
                self.model = preferences.model;
                self.effort = preferences.effort;
                self.fast_mode = preferences.fast_mode;
                self.ultrafast_mode = preferences.ultrafast_mode;
            }
        }
        self.session.configureWebFetchArtifactBlobs(self.alloc, try v2.childCapability(), v2.id());
        try self.startV2SubagentHost(v2);

        self.v2 = v2;
    }

    fn startV2SubagentHost(self: *AskContext, v2: *session_adapter.Session) !void {
        const children = try self.alloc.create(subagent_child_state.V2Children);
        errdefer self.alloc.destroy(children);
        children.* = subagent_child_state.V2Children.init(self.alloc, v2, self.workspace_root);
        errdefer children.deinit();
        self.subagent_host = subagent_tool_host.Runtime.create(
            self.alloc,
            children,
            .{ .context = self, .resolve_fn = resolveAskSubagentAuthority },
            .{ .context = self, .run_fn = runAskChild },
        ) catch |err| {
            if (err == error.OutOfMemory) return err;
            debug_trace.logf("subagent", "ask subagent host unavailable root_id={s} err={s}", .{ v2.id(), @errorName(err) });
            children.deinit();
            self.alloc.destroy(children);
            return;
        };
        self.v2_children = children;
        self.subagent_host.?.setLifecycle(.{ .view = self.lifecycle_view, .workspace_root = self.workspace_root });
        self.subagent_host.?.report_sink = .{ .context = self, .post_fn = postAskReport };
        self.subagent_host.?.background_work = .{ .context = self, .live_fn = askBackgroundWorkLive };

        self.subagent_host.?.resumeReports(v2);
    }

    fn toolContext(self: *AskContext) tool_runtime.Context {
        const provider_capabilities = self.cfg.provider_set.select(self.provider).capabilities;
        if (provider_capabilities.fx_search) {
            self.web_search_runtime.configure(.{
                .api_key = self.api_key,
                .credential_source = self.credential_source,
                .gateway_team = self.gateway_team,
                .worker_model = self.model,
                .gateway_retry_count = self.cfg.gateway_retry_count,
                .gateway_chat_url = self.cfg.gateway_chat_url,
            });
        }
        var tc: tool_runtime.Context = .{
            .workspace_root = self.workspace_root,
            .access_scope = self.workspace_access.scope(self.workspace_root),
            .ignored_list_entries = self.cfg.ignored_list_entries,
            .max_list_entries = self.cfg.max_list_entries,
            .max_read_file_bytes = self.cfg.max_read_file_bytes,
            .max_read_file_lines = self.cfg.max_read_file_lines,
            .max_read_file_line_len = self.cfg.max_read_file_line_len,
            .max_command_output_bytes = self.cfg.max_command_output_bytes,
            .max_tool_result_bytes = self.max_tool_result_bytes,
            .auto_compact_percent = self.auto_compact_percent,
            .api_key = self.api_key,
            .agent_stream_provider = self.agentStreamProvider(),
            .gateway_team = self.gateway_team,
            .credential_source = self.credential_source,
            .account_id = self.account_id,
            .provider = self.provider,
            .provider_capabilities = provider_capabilities,
            .oauth_transport = self.cfg.gateway_provider.oauth_transport,
            .secret_store = self.cfg.secret_store,
            .model = self.model,
            .reviewer_model = self.reviewer_model,
            .gateway_retry_count = self.cfg.gateway_retry_count,
            .gateway_chat_url = self.cfg.gateway_chat_url,
            .gateway_models_path = self.cfg.gateway_models_path,
            .agent_step_limit = self.agent_step_limit,
            .fast_mode = self.fast_mode,
            .ultrafast_mode = self.ultrafast_mode,
            .effort = self.effort,
            .provider_order = if (self.provider == .gateway) self.provider_order else &.{},
            .provider_strict = self.provider == .gateway and self.provider_strict,
            .first_call_tool_choice = self.first_call_tool_choice,
            .permission_mode = self.permission_mode,
            .permission_grants = &.{},
            .permission_rules = self.permission_rules,
            .tool_registry = self.toolRegistry(),
            .subagent_host = self.subagent_host,
            .subagent_caller_id = self.activeSessionId(),
            .auto_classifier = self.admissionAutoClassifier(),
            .worker = &self.worker,
            .cancel_flag = self.cancelFlag(),
            .session = &self.session,
            .todo = .{
                .state = &self.session.agent.todo,
                .history = self.session.agent.history.items,
            },
            .goal = self.goalView(),
            .session_allocator = self.alloc,
            .skills_dir = self.skills_dir,
            .context_limits = self.context_limits,
            .context_enabled = self.context_enabled,
            .context_registry = self.deps.context_registry,
            .output_chunk_ctx = @ptrCast(self),
            .on_output_chunk = onCommandOutputChunk,
            .mcp_progress_ctx = @ptrCast(self),
            .on_mcp_progress = onMcpProgress,
            .session_child_capability = self.sessionChildCapability(),
            .ephemeral_command_replay = self.managed_executions.replayStore(),
            .terminal_client = &self.terminal_client,
            .managed_executions = &self.managed_executions,
            .command_timeout_ms = self.command_timeout_ms,
            .web_fetch_runtime = &self.web_fetch_runtime,
            .web_fetch_artifact_store = self.session.webFetchArtifactStore(),
            .web_fetch_artifact_error = self.session.webFetchArtifactError(),
            .web_fetch_progress_ctx = @ptrCast(self),
            .on_web_fetch_progress = onWebFetchProgress,
            .web_search_runtime_ready = false,
            .notify_user_ready = self.deps.notify_user_enabled,
            .sensitive_file_guard = self.deps.sensitive_file_guard,
            .workspace_in_git_work_tree = self.deps.workspace_in_git_work_tree,
            .web_search_backend = if (provider_capabilities.fx_search) self.web_search_runtime.dispatchBackend() else null,
            .web_search_progress_ctx = @ptrCast(self),
            .on_web_search_progress = onWebSearchProgress,
            .model_capability_resolver = .{
                .ctx = @ptrCast(self),
                .resolve_fn = resolveModelCapabilities,
            },
            .model_override_resolver = .{
                .context = @ptrCast(self),
                .resolve_fn = resolveModelOverride,
            },
            .interactive = false,
            .lifecycle_view = self.lifecycle_view,
            .lifecycle_scope = self.lifecycleContext().scope,
        };
        if (self.mcp_host) |h| h.catalog.wire(&tc);

        if (self.mcp_host != null and self.mcp_elicitation_capabilities.any()) {
            tc.mcp_input_responder = .{
                .context = @ptrCast(self),
                .capabilities = self.mcp_elicitation_capabilities,
                .legacy_url_manual_completion = true,
                .callback = respondToAskMcpInput,
            };
        }
        return tc;
    }

    fn modelVisibleProjectContext(self: *const AskContext) []const u8 {
        if (!self.context_enabled) return "";
        return self.context_snapshot.modelVisibleBytes();
    }

    fn toolRegistry(self: *const AskContext) tool_dispatch.Registry {
        return self.deps.tool_set.registry;
    }

    fn admissionAutoClassifier(self: *AskContext) permission_auto_classifier.Classifier {
        if (self.auto_classifier.enabled()) return self.auto_classifier;
        const provider = self.cfg.provider_set.select(self.provider).permission_reviewer orelse
            return permission_auto_classifier.Classifier.disabled();
        return permission_auto_classifier.Classifier.withProvider(provider, .{
            .credential = self.api_key,
            .credential_source = self.credential_source,
            .account_id = self.account_id,
            .tenant = self.gateway_team,
            .endpoint = self.cfg.gateway_chat_url,
            .reviewer_model = self.reviewer_model,
            .cancel_flag = self.cancelFlag(),
        });
    }

    fn agentStreamProvider(self: *const AskContext) agent_stream_provider.Provider {
        return self.cfg.provider_set.select(self.provider).agent_stream_or_unavailable();
    }

    fn writeStdout(self: *AskContext, text: []const u8) !void {
        self.deps.write_stdout(self.deps.stdout_ctx, text) catch |err| {
            if (err == error.OutputReaderGone or err == error.BrokenPipe) {
                self.output_reader_gone = true;
            } else {
                self.output_write_failed = true;
            }
            return err;
        };
    }

    fn writeStderr(self: *AskContext, text: []const u8) !void {
        try self.deps.write_stderr(self.deps.stderr_ctx, text);
    }

    fn conversionNotice(context: ?*anyopaque, text: []const u8) void {
        const self: *AskContext = @ptrCast(@alignCast(context.?));
        self.writeStderr("fx ask: ") catch return;
        self.writeLine(text) catch {};
    }

    fn writeLine(self: *AskContext, text: []const u8) !void {
        try self.writeStderr(text);
        try self.writeStderr("\n");
    }
};

pub fn run(alloc: Allocator, args: []const [:0]const u8, cfg: Config, context_registry: context_contract.Registry, tool_set: tool_set_contract.ToolSet) !u8 {
    return runAs(alloc, .ask_command, args, cfg, context_registry, tool_set);
}

pub fn runAs(alloc: Allocator, invocation: Invocation, args: []const [:0]const u8, cfg: Config, context_registry: context_contract.Registry, tool_set: tool_set_contract.ToolSet) !u8 {
    return runWithDeps(alloc, args, cfg, .{
        .load_startup_state = loadStartupStateDefault,
        .context_registry = context_registry,
        .tool_set = tool_set,
        .load_mcp_host = cfg.load_mcp_host,
        .install_headless_interrupt = true,
        .invocation = invocation,
    });
}

fn selectOutputMode(quiet: bool, json: bool, stdout_is_tty: bool, no_color: bool) OutputMode {
    if (json) return .json;
    if (quiet) return .quiet;
    if (!stdout_is_tty) return .raw;
    return if (no_color) .terminal_no_color else .terminal;
}

fn askElicitationCapabilities(
    output_mode: OutputMode,
    stdin_is_tty: bool,
    stderr_is_tty: bool,
) @import("../mcp/elicitation.zig").Capabilities {
    if (!output_mode.isTerminal() or !stdin_is_tty or !stderr_is_tty) return .{};
    return .{ .form = true, .url = true };
}

fn checkHeadlessCancellation(deps: RunDeps) !void {
    if (comptime supports_headless_interrupt) {
        if (deps.install_headless_interrupt and
            headless_interrupt.cancel_requested.load(.seq_cst))
        {
            return error.Cancelled;
        }
    }
}

fn writeAskUsage(deps: RunDeps, usage: []const u8) !void {
    try deps.write_stderr(deps.stderr_ctx, "usage: fx ");
    try deps.write_stderr(deps.stderr_ctx, usage);
    try deps.write_stderr(deps.stderr_ctx, "\n");
}

fn askErrorNotice(err: anyerror) ?[]const u8 {
    if (auth_runtime.preparationFailureNotice(err)) |notice| return notice;
    if (config_runtime.modelNotSelectedMessage(err)) |message| return message;
    if (mcp_verbs.profileConfigNotice(err)) |notice| return notice;
    return switch (err) {
        error.ImagePreparationFailed => image_attachments.image_preparation_failed_notice,
        error.ModelImageCapabilityUnavailable => image_attachments.model_image_capability_unavailable_notice,
        error.GoalObjectiveRequired => "Provide a goal objective, e.g. `/goal Ship feature X`.",
        else => null,
    };
}

fn runWithDeps(alloc: Allocator, args: []const [:0]const u8, cfg: Config, deps: RunDeps) !u8 {
    var interrupt_scope = try headless_interrupt.Scope.install(
        deps.install_headless_interrupt,
    );
    defer interrupt_scope.restoreAndRedeliver();

    var problem: AskUsageProblem = .none;
    var options = parseInvocationOptions(alloc, deps.invocation, args, deps.stdin_source, &problem) catch |err| switch (err) {
        error.MissingPrompt => {
            if (hasJsonFlag(args)) {
                const json = try renderErrorJsonResult(alloc, @errorName(err), output_contracts.usage_exit_code);
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return output_contracts.usage_exit_code;
            }
            if (deps.invocation == .prompt_flag) {
                try deps.write_stderr(deps.stderr_ctx, prompt_flag_error_prefix ++ "Prompt cannot be empty.\n");
                return prompt_flag_error_exit_code;
            }
            try deps.write_stderr(deps.stderr_ctx, "fx ask: missing prompt\n");
            try writeAskUsage(deps, cfg.command_usage);
            return output_contracts.usage_exit_code;
        },
        error.NoSaveResumeConflict => {
            if (hasJsonFlag(args)) {
                const json = try renderErrorJsonResult(alloc, "InvalidAskArgs", output_contracts.usage_exit_code);
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return output_contracts.usage_exit_code;
            }
            try deps.write_stderr(deps.stderr_ctx, "fx ask: --no-save cannot be used with --resume\n");
            try writeAskUsage(deps, cfg.command_usage);
            return output_contracts.usage_exit_code;
        },
        error.PromptResourceLimitExceeded => {
            if (hasJsonFlag(args)) {
                const json = try renderErrorJsonResult(alloc, @errorName(err), 1);
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return 1;
            }
            try deps.write_stderr(deps.stderr_ctx, "fx ask: prompt exceeds the local input safety limit\n");
            return 1;
        },
        error.PromptInputReadFailed => {
            if (hasJsonFlag(args)) {
                const json = try renderErrorJsonResult(alloc, @errorName(err), 1);
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return 1;
            }
            try deps.write_stderr(deps.stderr_ctx, "fx ask: failed to read prompt from stdin\n");
            return 1;
        },
        error.InvalidAskArgs => {
            if (hasJsonFlag(args)) {
                const json = try renderErrorJsonResult(alloc, @errorName(err), output_contracts.usage_exit_code);
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return output_contracts.usage_exit_code;
            }
            if (deps.invocation == .prompt_flag) {
                try writeAskUsageProblem(alloc, deps, problem, prompt_flag_error_prefix);
                return prompt_flag_error_exit_code;
            }
            try writeAskUsageProblem(alloc, deps, problem, ask_error_prefix);
            try writeAskUsage(deps, cfg.command_usage);
            return output_contracts.usage_exit_code;
        },
        error.InvalidPromptText => {
            if (hasJsonFlag(args)) {
                const json = try renderErrorJsonResult(alloc, @errorName(err), 1);
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return 1;
            }
            try deps.write_stderr(deps.stderr_ctx, "fx ask: prompt must be valid UTF-8 and contain no NUL bytes\n");
            return 1;
        },
        else => return err,
    };
    defer options.deinit(alloc);

    if (interrupt_scope.requested()) return headless_interrupt.exitCode();
    if (options.image_paths.items.len > 0) {
        const workspace_root = try io_mod.realpathAlloc(alloc, ".");
        defer alloc.free(workspace_root);
        if (!try preflightAskImages(alloc, workspace_root, &options, deps)) return 1;
    }
    if (interrupt_scope.requested()) return headless_interrupt.exitCode();

    var effective_cfg = cfg;
    if (options.system_prompt_override) |sp| {
        effective_cfg.prompt_policy.system_prompt = sp;
    }
    const appended_system_prompt: ?[]u8 = if (options.system_prompt_append) |appended|
        try claude_flags.appendedSystemPrompt(alloc, effective_cfg.prompt_policy.system_prompt, appended)
    else
        null;
    defer if (appended_system_prompt) |composed| alloc.free(composed);
    if (appended_system_prompt) |composed| effective_cfg.prompt_policy.system_prompt = composed;
    var plugin_arena: std.heap.ArenaAllocator = .init(alloc);
    defer plugin_arena.deinit();
    var plugins: []const plugin_manager.Plugin = &.{};
    if (io_mod.homeDir()) |home| {
        plugins = plugin_manager.list(plugin_arena.allocator(), home) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => &.{},
        };
    }
    effective_cfg.prompt_policy.system_prompt = try plugin_contributions.withSystemPrompts(plugin_arena.allocator(), effective_cfg.prompt_policy.system_prompt, plugins);

    const stream_json = switch (resolveRunOutputFormat(&options, deps)) {
        .format => |format| format == .stream_json,
        .invalid_env => |bad| {
            var message: std.Io.Writer.Allocating = .init(alloc);
            defer message.deinit();
            try message.writer.writeAll(usageErrorPrefix(deps.invocation));
            try bad.write(&message.writer);
            try message.writer.writeByte('\n');
            try deps.write_stderr(deps.stderr_ctx, message.written());
            return usageErrorExitCode(deps.invocation);
        },
    };
    if (stream_json) {
        var version_line: std.Io.Writer.Allocating = .init(alloc);
        defer version_line.deinit();
        try print_stream.writeVersion(&version_line.writer, build_options.app_version);
        try deps.write_stdout(deps.stdout_ctx, version_line.written());
    }

    const no_color = options.no_color or terminal_env.colorDisabled();
    const output_mode = selectOutputMode(
        options.quiet,
        options.json_output or stream_json,
        deps.stdout_is_tty(deps.stdout_ctx),
        no_color,
    );
    const result = runPromptInternal(alloc, options.prompt, options.agent.permission, effective_cfg, .{
        .output_mode = output_mode,
        .stream_json = stream_json,
        .prompt_permissions = options.prompt_permissions,
        .bare = options.bare,
        .allowed_tools = options.allowed_tools.items,
        .tools = options.tools,
        .disallowed_tools = options.disallowed_tools.items,
        .images = if (options.images.items.len > 0) options.images.items else &.{},
        .command_timeout_ms = options.timeout_ms,
        .save_session = !options.no_save,
        .session_name = options.session_name,
        .resume_target = options.resume_target,
        .color_enabled = !no_color,
        .provider_override = options.agent.provider,
        .model_override = options.agent.model,
        .effort_override = options.agent.effort,
        .fast_override = options.agent.fast,
        .ultrafast_override = options.agent.ultrafast,
        .provider_order_override = options.agent.provider_order,
        .provider_strict_override = options.agent.provider_strict,
        .settings_overrides = options.settings_overrides.items,
        .deps = deps,
    }) catch |err| {
        if (interrupt_scope.requested()) return headless_interrupt.exitCode();
        if (err == error.OutOfMemory) return err;
        if (err == error.SessionBusy) return reportSessionOccupied(alloc, deps, options.json_output, stream_json, options.resume_target);
        if (err == error.OneOffSessionNotResumable and !options.json_output) {
            try deps.write_stderr(
                deps.stderr_ctx,
                "fx ask: subagent child sessions cannot be resumed directly; message the named agent from its parent session\n",
            );
            return 1;
        }
        if (err == error.UnknownConfiguredProvider) {
            const from_flag = options.agent.provider != null;
            const code: u8 = if (from_flag) output_contracts.usage_exit_code else 1;
            const name = if (options.agent.provider) |provider| provider.label() else config_runtime.providerEnvOverride() orelse "";
            if (options.json_output) {
                const json = try renderErrorJsonResult(alloc, @errorName(err), code);
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return code;
            }
            const message = try config_runtime.unknownProviderMessage(alloc, name);
            defer alloc.free(message);
            try deps.write_stderr(deps.stderr_ctx, "fx ask: ");
            try deps.write_stderr(deps.stderr_ctx, message);
            try deps.write_stderr(deps.stderr_ctx, "\n");
            return code;
        }
        if (!options.json_output) {
            const notice = askErrorNotice(err) orelse return err;
            try deps.write_stderr(deps.stderr_ctx, "fx ask: ");
            try deps.write_stderr(deps.stderr_ctx, notice);
            try deps.write_stderr(deps.stderr_ctx, "\n");
            try writeFailureLogHint(deps, debug_trace.activeLogPath());
            return 1;
        }
        const json = try renderErrorJsonResult(alloc, @errorName(err), 1);
        defer alloc.free(json);
        try deps.write_stdout(deps.stdout_ctx, json);
        return 1;
    };
    defer result.deinit(alloc);

    if (result.interrupted or interrupt_scope.requested()) {
        return headless_interrupt.exitCode();
    }

    if (result.output_reader_gone) return error.OutputReaderGone;
    if (result.output_write_failed) return error.OutputWriteFailed;

    if (options.json_output) {
        const json = try renderFinalJsonResult(alloc, result);
        defer alloc.free(json);
        if (interrupt_scope.requested()) return headless_interrupt.exitCode();
        try deps.write_stdout(deps.stdout_ctx, json);
    }

    if (stream_json and result.exit_code != 0) {
        if (result.error_code) |error_code| {
            try deps.write_stderr(deps.stderr_ctx, "error: ");
            try deps.write_stderr(deps.stderr_ctx, error_code);
            try deps.write_stderr(deps.stderr_ctx, "\n");
        }
    }
    if (!options.json_output and result.exit_code != 0) try writeFailureLogHint(deps, debug_trace.activeLogPath());

    if (!options.json_output and !options.no_save and result.exit_code == 0 and result.session_id.len > 0) {
        try writeResumeHint(alloc, deps, result.session_id, stream_json);
    }

    return if (interrupt_scope.requested())
        headless_interrupt.exitCode()
    else
        result.exit_code;
}

fn writeResumeHint(alloc: Allocator, deps: RunDeps, session_id: []const u8, stream_json: bool) !void {
    if (stream_json) {
        var line: std.Io.Writer.Allocating = .init(alloc);
        defer line.deinit();
        try print_stream.writeResumeHint(alloc, &line.writer, session_id);
        try deps.write_stdout(deps.stdout_ctx, line.written());
        return;
    }
    const hint = try std.fmt.allocPrint(alloc, "To resume this session: fx -r {s}\n", .{session_id});
    defer alloc.free(hint);
    try deps.write_stderr(deps.stderr_ctx, hint);
}

const ask_error_prefix = "fx ask: ";
const prompt_flag_error_prefix = "error: ";
const prompt_flag_error_exit_code: u8 = 1;

fn usageErrorPrefix(invocation: Invocation) []const u8 {
    return if (invocation == .prompt_flag) prompt_flag_error_prefix else ask_error_prefix;
}

fn usageErrorExitCode(invocation: Invocation) u8 {
    return if (invocation == .prompt_flag) prompt_flag_error_exit_code else output_contracts.usage_exit_code;
}

fn resolveRunOutputFormat(options: *const AskOptions, deps: RunDeps) print_stream.Resolution {
    if (options.output_format == null and (options.json_output or options.quiet)) return .{ .format = .text };
    const env_defaults = deps.output_format_env();
    return print_stream.resolveOutputFormat(options.output_format, &env_defaults);
}

fn busySessionId(alloc: Allocator, target: ?ResumeTarget) ?[]u8 {
    const resolved = target orelse return null;
    switch (resolved) {
        .id => |id| return alloc.dupe(u8, id) catch null,
        .last => {},
    }
    var store = session_adapter.Store.openFromEnv(alloc) catch return null;
    defer store.deinit(alloc);
    const workspace_root = io_mod.realpathAlloc(alloc, ".") catch return null;
    defer alloc.free(workspace_root);
    return session_adapter.newestListed(&store, alloc, workspace_root) catch null;
}

fn reportSessionOccupied(alloc: Allocator, deps: RunDeps, json_output: bool, stream_json: bool, target: ?ResumeTarget) !u8 {
    if (stream_json) {
        var line: std.Io.Writer.Allocating = .init(alloc);
        defer line.deinit();
        const session_id = busySessionId(alloc, target);
        defer if (session_id) |id| alloc.free(id);
        try print_stream.writeErrorWithSession(&line.writer, print_stream.session_occupied_code, print_stream.session_occupied_message, session_id);
        try deps.write_stdout(deps.stdout_ctx, line.written());
    } else if (json_output) {
        const json = try renderErrorJsonResult(alloc, "SessionBusy", print_stream.session_occupied_exit_code);
        defer alloc.free(json);
        try deps.write_stdout(deps.stdout_ctx, json);
    } else {
        try deps.write_stderr(deps.stderr_ctx, usageErrorPrefix(deps.invocation));
        try deps.write_stderr(deps.stderr_ctx, print_stream.session_occupied_message ++ "\n");
    }
    return print_stream.session_occupied_exit_code;
}

fn writeFailureLogHint(deps: RunDeps, log_path: ?[]const u8) !void {
    const path = log_path orelse return;
    try deps.write_stderr(deps.stderr_ctx, "See log: ");
    try deps.write_stderr(deps.stderr_ctx, path);
    try deps.write_stderr(deps.stderr_ctx, "\n");
}

fn preflightAskImages(
    alloc: Allocator,
    workspace_root: []const u8,
    options: *AskOptions,
    deps: RunDeps,
) !bool {
    for (options.image_paths.items) |image_path| {
        const attachment = image_attachments.loadUserImageAttachment(
            alloc,
            workspace_root,
            image_path,
        ) catch |err| {
            if (err == error.OutOfMemory) return err;
            const reason = switch (err) {
                error.FileNotFound => "image file not found",
                error.UnsupportedImageType => "unsupported image type",
                error.ImageTooLarge => image_attachments.image_too_large_notice,
                else => @errorName(err),
            };
            if (options.json_output) {
                const detail = try alloc.print("{s}: {s}", .{ @errorName(err), image_path });
                defer alloc.free(detail);
                const json = try renderErrorJsonResult(alloc, detail, 1);
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
            } else {
                var message: std.Io.Writer.Allocating = .init(alloc);
                defer message.deinit();
                try message.writer.print("fx ask: failed to attach image \"{s}\": {s}\n", .{ image_path, reason });
                try deps.write_stderr(deps.stderr_ctx, message.written());
            }
            return false;
        };
        var attachment_owned = true;
        errdefer if (attachment_owned) types.freeImageAttachment(alloc, attachment);
        try options.images.append(alloc, attachment);
        attachment_owned = false;
    }
    return true;
}

pub fn runPrompt(alloc: Allocator, prompt: []const u8, agent: agent_run_flags.Overrides, cfg: Config, context_registry: context_contract.Registry, tool_set: tool_set_contract.ToolSet) !u8 {
    const result = try runPromptWithRunFlags(alloc, prompt, agent, cfg, context_registry, tool_set, .raw);
    defer result.deinit(alloc);
    if (result.output_reader_gone) return error.OutputReaderGone;
    if (result.output_write_failed) return error.OutputWriteFailed;
    return result.exit_code;
}

pub fn runPromptCapture(alloc: Allocator, prompt: []const u8, agent: agent_run_flags.Overrides, cfg: Config, context_registry: context_contract.Registry, tool_set: tool_set_contract.ToolSet) !PromptRunResult {
    return runPromptWithRunFlags(alloc, prompt, agent, cfg, context_registry, tool_set, .json);
}

fn runPromptWithRunFlags(
    alloc: Allocator,
    prompt: []const u8,
    agent: agent_run_flags.Overrides,
    cfg: Config,
    context_registry: context_contract.Registry,
    tool_set: tool_set_contract.ToolSet,
    output_mode: OutputMode,
) !PromptRunResult {
    return runPromptInternal(alloc, prompt, agent.permission, cfg, .{
        .output_mode = output_mode,
        .images = &.{},
        .provider_override = agent.provider,
        .model_override = agent.model,
        .effort_override = agent.effort,
        .fast_override = agent.fast,
        .ultrafast_override = agent.ultrafast,
        .provider_order_override = agent.provider_order,
        .provider_strict_override = agent.provider_strict,
        .deps = .{
            .context_registry = context_registry,
            .tool_set = tool_set,
            .load_mcp_host = cfg.load_mcp_host,
        },
    });
}

fn missingCredentialResult(
    alloc: Allocator,
    options: RunOptions,
    provider: model_provider.ProviderId,
    preferred: ?credentials.Source,
) !PromptRunResult {
    const status = auth_runtime.StatusSnapshot{
        .required_source = auth_runtime.requestedSource(provider, preferred),
    };
    const message = status.missingHelp(.cli).?;
    try options.deps.write_stderr(options.deps.stderr_ctx, "fx ask: ");
    try options.deps.write_stderr(options.deps.stderr_ctx, message);
    try options.deps.write_stderr(options.deps.stderr_ctx, "\n");
    return .{
        .exit_code = 1,
        .assistant_output = try alloc.dupe(u8, ""),
        .error_code = "MissingCredentials",
    };
}

fn runPromptInternal(alloc: Allocator, prompt: []const u8, permission_override: ?PermissionMode, initial_cfg: Config, options: RunOptions) !PromptRunResult {
    var cfg = initial_cfg;
    const goal_objective = try goalObjectiveFromPrompt(prompt);
    const owned_prompt = try alloc.dupe(u8, goal_objective orelse prompt);
    defer alloc.free(owned_prompt);

    try checkHeadlessCancellation(options.deps);
    var startup = if (cfg.auth_mode == .host_managed)
        try options.deps.load_startup_state_with_auth_mode(
            alloc,
            cfg.gateway_provider.oauth_transport,
            cfg.secret_store,
            cfg.default_model,
            cfg.default_agent_step_limit,
            cfg.auth_mode,
            options.provider_override,
            options.model_override,
            options.settings_overrides,
        )
    else
        try options.deps.load_startup_state(
            alloc,
            cfg.gateway_provider.oauth_transport,
            cfg.secret_store,
            cfg.default_model,
            cfg.default_agent_step_limit,
            options.provider_override,
            options.model_override,
            options.settings_overrides,
        );
    defer startup.deinit(alloc);
    applyAskThemeChoice(startup.theme);
    cfg.provider_set.definitions = startup.configured_providers.definitions;

    var gateway_pool: ?*http_pool.HttpPool = null;
    defer if (gateway_pool) |pool| {
        if (pool.deinit() == .destroyed) alloc.destroy(pool);
    };
    if (io_mod.getenv("FX_BENCH") == null and startup.provider == .gateway) {
        if (alloc.create(http_pool.HttpPool)) |pool| {
            pool.* = http_pool.HttpPool.init(alloc);
            gateway_pool = pool;
            if (cfg.provider_set.gateway.agent_stream) |stream| {
                var stamped = stream;
                stamped.context = pool;
                cfg.provider_set.gateway.agent_stream = stamped;
            }
            pool.warmAsync(gateway_client.resolveChatUrlForWarmup(cfg.gateway_chat_url));
        } else |_| {}
    }
    try checkHeadlessCancellation(options.deps);

    var permission_mode = toCorePermissionMode(startup.permission_mode);
    const mode_id: []const u8 = cfg.mode_registry.default_mode_id;
    if (permission_override) |explicit| permission_mode = explicit;

    if (permission_mode == .yolo and !startup.yolo_acknowledged) {
        try emitHeadlessYoloWarning(alloc, options);
    }
    if (startup.default_plan_mode) {
        try options.deps.write_stderr(options.deps.stderr_ctx, default_plan_mode_skipped_notice);
    }
    if (options.deps.load_mcp_host != null) {
        if (app_mcp_runtime.untrustedProjectServersWarning(alloc, io_mod.homeDir(), startup.workspace_root, app_mcp_runtime.trustEnvironmentSet())) |warning| {
            defer alloc.free(warning);
            try options.deps.write_stderr(options.deps.stderr_ctx, warning);
        }
    }

    for (startup.config_diagnostics) |diagnostic| {
        var notice_writer: std.Io.Writer.Allocating = .init(alloc);
        defer notice_writer.deinit();
        if (diagnostic.note()) |text| {
            try notice_writer.writer.print("fx ask: note: {s}", .{text});
        } else {
            try notice_writer.writer.print(
                "fx ask: config {s}: {s}",
                .{ @tagName(diagnostic.layer), @tagName(diagnostic.cause) },
            );
            try config_runtime.writeDiagnosticMetadata(&notice_writer.writer, diagnostic);
        }
        try notice_writer.writer.writeByte('\n');
        const notice = try notice_writer.toOwnedSlice();
        defer alloc.free(notice);
        try options.deps.write_stderr(options.deps.stderr_ctx, notice);
    }

    try app_lifecycle.applyWorkspaceLaunch(
        &startup,
        alloc,
        cfg.additional_directories,
        cfg.saved_directories_suppressed,
    );
    try checkHeadlessCancellation(options.deps);

    if (cfg.auth_mode == .local and
        options.resume_target == null and startup.credential == null)
    {
        if (startup.credential_load_failure) |failure| {
            if (auth_runtime.preparationError(auth_runtime.classifyCredentialFailure(failure.source, failure.err))) |err| return err;
        }
        return missingCredentialResult(alloc, options, startup.provider, startup.credential_source_preference);
    }

    var owned_resumed_model: ?[]u8 = null;
    defer if (owned_resumed_model) |model| alloc.free(model);
    var tool_arena: std.heap.ArenaAllocator = .init(alloc);
    defer tool_arena.deinit();
    var ask_deps = options.deps;
    ask_deps.notify_user_enabled = startup.notify_user_enabled;
    ask_deps.sensitive_file_guard = startup.sensitive_file_guard;
    ask_deps.workspace_in_git_work_tree = startup.workspace_in_git_work_tree;
    if (startup.notify_user_enabled) ask_deps.tool_set = builtin_tools.advertisementSetFor(true, false, true);
    ask_deps.tool_set = try narrowAskTools(tool_arena.allocator(), ask_deps.tool_set, options.tools, options.disallowed_tools);
    var ctx = AskContext.init(alloc, cfg, ask_deps, startup.workspace_root);
    ctx.session_name = options.session_name;
    defer ctx.deinit();
    if (goal_objective) |objective| _ = try ctx.goal.create(alloc, io_mod.milliTimestamp(), objective, null, false);
    if (!options.bare) ctx.command_hooks.replaceDefinitions(alloc, startup.takeHookDefinitions());
    ctx.use_process_interrupt_flag = options.deps.install_headless_interrupt;
    try ctx.checkCancellation();
    var presenter: ?ask_presentation.Runtime = null;
    defer if (presenter) |*value| value.deinit();
    var worker_events_drained = false;
    ctx.workspace_access = startup.takeWorkspaceAccess();
    ctx.output_mode = options.output_mode;
    if (options.stream_json) ctx.print_stream = print_stream.Stream.init(alloc);
    ctx.prompt_permissions = options.prompt_permissions;
    ctx.mcp_elicitation_capabilities = askElicitationCapabilities(
        options.output_mode,
        options.deps.stdin_is_tty(options.deps.stdin_ctx),
        options.deps.stderr_is_tty(options.deps.stderr_ctx),
    );
    ctx.command_timeout_ms = options.command_timeout_ms;
    ctx.model = startup.selected_model;
    ctx.provider = startup.provider;
    ctx.seed_model = startup.configured_model;
    ctx.requested_resume = options.resume_target;
    ctx.agent_step_limit = startup.agent_step_limit;
    ctx.max_tool_result_bytes = startup.max_tool_result_bytes;
    ctx.auto_compact_percent = startup.auto_compact_percent;
    ctx.context_limits = startup.context_limits;
    ctx.context_limits.applyCommandLine(cfg.context_limit_overrides);
    ctx.fast_mode = startup.fast_mode;
    ctx.persisted_ultrafast_mode = startup.configured_ultrafast_mode;
    ctx.ultrafast_mode = startup.ultrafast_mode;
    ctx.provider_order = startup.provider_order;
    ctx.provider_strict = startup.provider_strict;
    ctx.effort = toCoreReasoningEffort(startup.effort);
    ctx.first_call_tool_choice = startup.first_call_tool_choice;
    ctx.permission_mode = permission_mode;
    ctx.reviewer_model = startup.review_model;
    ctx.mode_id = mode_id;
    ctx.permission_rules = try takeCorePermissionRules(alloc, &startup);
    try appendAllowedTools(alloc, &ctx.permission_rules, options.allowed_tools);
    ctx.context_enabled = bareDiscovery(options.bare, startup.context_enabled);
    if (options.output_mode.isTerminal()) {
        presenter = try ask_presentation.Runtime.init(alloc, .{
            .text = owned_prompt,
            .images = @constCast(options.images),
        }, options.output_mode == .terminal_no_color);
        ctx.presenter = &presenter.?;
    }
    try ctx.configureNotifications(
        startup.notification_turn_end,
        startup.notification_attention_required,
    );
    ctx.session.setConversationLanguageFromUserMessage(owned_prompt);
    if (options.save_session) {
        try ctx.checkCancellation();
        try options.deps.initialize_session_stores(&ctx);
        try ctx.checkCancellation();

        if (options.provider_override != null or config_runtime.providerEnvOverride() != null) {
            ctx.provider = startup.provider;
            ctx.model = startup.selected_model;
        }
        if (startup.model_source == .process_override or startup.project_model_pinned) {
            ctx.model = startup.selected_model;
        } else if (ctx.requested_resume != null) {
            owned_resumed_model = try alloc.dupe(u8, ctx.model);
            ctx.model = owned_resumed_model.?;
        }

        if (startup.ultrafast_process_override) |ultrafast| ctx.ultrafast_mode = ultrafast;
        ctx.session.setConversationLanguageFromUserMessage(owned_prompt);
    }
    try ctx.startSessionLifecycle();

    if (options.model_override) |model| {
        ctx.model = model;
    }
    if (options.effort_override) |effort| {
        ctx.effort = effort;
    }
    if (options.fast_override) |fast| {
        ctx.fast_mode = fast;
        if (fast) ctx.ultrafast_mode = false;
    } else if (options.model_override != null and ctx.requested_resume == null and
        startup.fast_mode_source == .compiled_default)
    {
        ctx.fast_mode = false;
    }
    if (options.ultrafast_override) |ultrafast| {
        ctx.ultrafast_mode = ultrafast;
        if (ultrafast) ctx.fast_mode = false;
    } else if (options.model_override != null and ctx.requested_resume == null and
        startup.ultrafast_mode_source == .compiled_default)
    {
        ctx.ultrafast_mode = false;
    }
    if (options.provider_order_override) |order| {
        ctx.provider_order = order;
    }
    if (options.provider_strict_override) |strict| {
        ctx.provider_strict = strict;
    }

    var routed_credential: ?credentials.Credential = null;
    defer if (routed_credential) |*credential| credential.deinit(alloc);
    if (cfg.auth_mode == .host_managed) {
        ctx.api_key = "";
        ctx.gateway_team = null;
        ctx.credential_source = .host_managed;
        ctx.account_id = null;
        ctx.model_catalog_access = .host_managed;
    } else {
        const startup_matches_final_model = if (startup.credential) |credential|
            startup.provider.same_authority(ctx.provider) and model_provider.authorizesCredential(ctx.provider, credential.source)
        else
            false;
        const startup_credential_is_final = startup_matches_final_model and
            !credentials.sourceRefreshable(startup.credential.?.source);
        const credential: *const credentials.Credential = if (startup_credential_is_final)
            &startup.credential.?
        else routed: {
            const preferred_source = if (ctx.provider == .gateway) startup.credential_source_preference else null;
            routed_credential = try auth_runtime.prepareCredential(
                alloc,
                cfg.gateway_provider.oauth_transport,
                cfg.secret_store,
                ctx.provider,
                preferred_source,
            );
            if (routed_credential == null) {
                return missingCredentialResult(alloc, options, ctx.provider, preferred_source);
            }
            break :routed &routed_credential.?;
        };
        ctx.api_key = credential.token;
        ctx.gateway_team = credential.gatewayTeam();
        ctx.credential_source = credential.source;
        ctx.account_id = credential.accountId();
        ctx.model_catalog_access = credentials.catalogAccessForCredentialAndAccount(
            credential.source,
            credential.token,
            credential.gatewayTeam(),
            credential.accountId(),
        );
    }

    const restored_image_catalog = try ctx.session.snapshotImageCatalog(alloc, &.{});
    defer types.freeImageAttachmentSlice(alloc, restored_image_catalog);
    const restored_image_bounds = try image_attachments.calculate_next_image_id(restored_image_catalog);

    const current_images = try types.dupeImageAttachmentSlice(alloc, options.images);
    defer types.freeImageAttachmentSlice(alloc, current_images);
    defer if (options.save_session and !ctx.prompt_snapshot_committed) {
        image_attachments.deleteUnreferencedImageSnapshots(current_images, restored_image_catalog);
    };
    if (current_images.len > 0) {
        try ctx.checkCancellation();
        _ = std.math.add(
            usize,
            restored_image_bounds.next_id,
            current_images.len - 1,
        ) catch return failPromptRunResult(error.ImageIdOverflow);
        for (current_images, 0..) |*image, index| image.id = restored_image_bounds.next_id + index;
        try ctx.captureImageAttachments(current_images);
        try ctx.checkCancellation();
    }

    const authorized_image_catalog = try ctx.session.snapshotImageCatalog(alloc, current_images);
    defer types.freeImageAttachmentSlice(alloc, authorized_image_catalog);

    try ctx.checkCancellation();
    if (bareDiscovery(options.bare, true)) ctx.loaded_skills = try options.deps.load_skills(
        alloc,
        startup.workspace_root,
        cfg.skill_root_policy,
    );
    const loaded_skills = &ctx.loaded_skills;
    try ctx.checkCancellation();
    skill_runtime.traceDiagnostics("ask_startup", loaded_skills.diagnostics);
    ctx.skills_dir = loaded_skills.dir;
    loaded_skills.dir = &.{};
    if (ctx.context_enabled) {
        try ctx.checkCancellation();
        const context_targets = try context_contract.applicableTargetsForImages(alloc, current_images);
        defer if (context_targets.len > 0) alloc.free(context_targets);
        ctx.context_snapshot = try ctx.deps.context_registry.gatherDefaultSnapshot(alloc, .{
            .workspace_root = startup.workspace_root,
            .access_scope = ctx.workspace_access.scope(ctx.workspace_root),
            .targets = context_targets,
            .context_limits = ctx.context_limits,
        });
        try ctx.checkCancellation();
        for (ctx.context_snapshot.notices) |notice| try pushContextNotice(@ptrCast(&ctx), notice);
    }

    try ctx.checkCancellation();
    if (bareDiscovery(options.bare, true)) {
        if (options.deps.load_mcp_host) |load_host| {
            ctx.mcp_host = try load_host(alloc, startup.workspace_root, ctx.toolRegistry(), .{ .questions = ctx.mcp_elicitation_capabilities });
            if (ctx.mcp_host) |h| try reportUnapprovedMcpServers(&ctx, h);
        }
    }
    try ctx.checkCancellation();
    const session_child_capability = ctx.sessionChildCapability();
    var tool_projection = try buildAskGatewayToolProjection(alloc, ctx.cfg.mode_registry, ctx.deps.tool_set, ctx.mode_id, .{
        .permission_mode = ctx.permission_mode,
        .permission_rules = ctx.permission_rules,
        .subagent_available = ctx.subagent_host != null,
    }, session_child_capability != null);
    defer tool_projection.deinit(alloc);

    const context_history = try ctx.session.snapshotHistory(alloc);
    defer types.freeHistoryTurnSlice(alloc, context_history);
    const root_user_intent_context = try auto_classifier_context.buildCanonicalRootUserContext(
        alloc,
        owned_prompt,
        ctx.session.agent.history.items,
    );
    defer alloc.free(root_user_intent_context);
    ctx.active_turn_id = debug_trace.nextTurnId();

    const job: worker_runtime.QueuedPrompt = .{
        .turn_id = ctx.active_turn_id,
        .prompt = owned_prompt,
        .images = current_images,
        .authorized_image_catalog = authorized_image_catalog,
        .model = @constCast(ctx.model),
        .api_key = @constCast(ctx.api_key),
        .gateway_team = if (ctx.gateway_team) |team| @constCast(team) else null,
        .credential_source = ctx.credential_source,
        .account_id = if (ctx.account_id) |account_id| @constCast(account_id) else null,
        .provider = ctx.provider,
        .permission_mode = ctx.permission_mode,
        .history = context_history,
        .unversioned_history_count = ctx.session.unversionedHistoryEnd(),
        .root_user_intent_context = root_user_intent_context,
        .grants = &.{},

        .context_snapshot = ctx.context_snapshot,
        .stale_shell_handles = ctx.session.takeStaleShellHandles(),
    };

    const deps = agentRuntimeDeps(&ctx);
    const semantic_presentation = if (ctx.presenter) |value| value.semanticSink() else null;
    try ctx.checkCancellation();
    const title_task = maybeStartAskTitleTask(
        &ctx,
        startup.session_title_generation,
        owned_prompt,
        options.save_session and ctx.requested_resume == null and ctx.session_name == null,
    );
    defer if (title_task) |task| completeAskTitleTask(&ctx, task);
    var top_level_mcp_tools: std.heap.ArenaAllocator = .init(alloc);
    defer top_level_mcp_tools.deinit();
    const turn_config: agent_runtime.Config = .{
        .initial_dynamic_tools = topLevelMcpTools(&ctx, top_level_mcp_tools.allocator()),
        .system_prompt = cfg.prompt_policy.system_prompt,
        .model_prompt_overlay = cfg.prompt_policy.modelPromptOverlay(ctx.model),
        .skill_catalog = .{ .skills = loaded_skills.skills, .diagnostics = loaded_skills.diagnostics },
        .gateway_retry_count = cfg.gateway_retry_count,
        .gateway_chat_url = cfg.gateway_chat_url,
        .advertised_tool_names = tool_projection.advertised_names,
        .advertised_functions = tool_projection.advertised_functions,
        .provider_capabilities = cfg.provider_set.select(ctx.provider).capabilities,
        .custom_tool_guidance = tool_projection.custom_guidance,
        .agent_step_limit = startup.agent_step_limit,
        .max_tool_result_bytes = startup.max_tool_result_bytes,
        .auto_compact_percent = startup.auto_compact_percent,
        .cancel_flag = ctx.cancelFlag(),
        .fast_mode = ctx.fast_mode,
        .ultrafast_mode = ctx.ultrafast_mode,
        .effort = ctx.effort,
        .provider_order = if (ctx.provider == .gateway) ctx.provider_order else &.{},
        .provider_strict = ctx.provider == .gateway and ctx.provider_strict,
        .first_call_tool_choice = ctx.first_call_tool_choice,
        .workspace_root = ctx.workspace_root,
        .access_scope = ctx.workspace_access.scope(ctx.workspace_root),
        .context_limits = ctx.context_limits,
        .session_child_capability = session_child_capability,
        .ephemeral_command_replay = if (session_child_capability == null)
            &ctx.ephemeral_command_replay
        else
            null,
    };
    const first_turn = runAskTurn(&ctx, alloc, options, &deps, semantic_presentation, turn_config, job) catch |err| return goalCancelResult(&ctx, alloc, err);
    if (first_turn) |early| return early;

    const print_policy = managed_contract.taskSettings();
    const background_wait_deadline_ms = managed_contract.printWaitDeadlineMs(io_mod.milliTimestamp(), print_policy);
    var turns_run: usize = 1;
    while (goalSnapshot(&ctx)) |snapshot| {
        if (snapshot.status != .active) break;
        if (!managed_contract.printTurnAllowed(turns_run, print_policy)) {
            try ctx.writeStderr("fx ask: stopped after the most turns one request takes (task.print_max_turns)\n");
            _ = try ctx.goal.markBlocked(alloc, io_mod.milliTimestamp(), goal_turn_limit_reason);
            break;
        }
        turns_run += 1;
        ctx.checkCancellation() catch |err| return goalCancelResult(&ctx, alloc, err);
        const continuation = try goal_reminder.render(alloc, snapshot, true, false);
        defer alloc.free(continuation);
        const history = try ctx.session.snapshotHistory(alloc);
        defer types.freeHistoryTurnSlice(alloc, history);
        ctx.active_turn_id = debug_trace.nextTurnId();
        var follow = job;
        follow.turn_id = ctx.active_turn_id;
        follow.prompt = continuation;
        follow.delivery = .continuation;
        follow.images = &.{};
        follow.authorized_image_catalog = &.{};
        follow.history = history;
        follow.unversioned_history_count = ctx.session.unversionedHistoryEnd();
        const next_turn = runAskTurn(&ctx, alloc, options, &deps, semantic_presentation, turn_config, follow) catch |err| return goalCancelResult(&ctx, alloc, err);
        if (next_turn) |early| return early;
    }
    while (ctx.subagent_host) |tree| {
        if (print_policy.print_background_mode == .exit) break;
        switch (tree.awaitMailOrQuietUntil(&ctx.worker, ctx.cancelFlag(), background_wait_deadline_ms)) {
            .quiet, .stopped => break,
            .mail => {},
        }
        const next = ctx.worker.takeQueuedPrompt(std.heap.c_allocator) orelse continue;
        defer worker_runtime.freeQueuedPrompt(std.heap.c_allocator, next);
        if (print_policy.print_background_mode == .drain) continue;
        if (!managed_contract.printTurnAllowed(turns_run, print_policy)) {
            try ctx.writeStderr("fx ask: stopped after the most turns one request takes (task.print_max_turns)\n");
            break;
        }
        turns_run += 1;
        try ctx.checkCancellation();
        const history = try ctx.session.snapshotHistory(alloc);
        defer types.freeHistoryTurnSlice(alloc, history);
        ctx.active_turn_id = debug_trace.nextTurnId();
        var follow = job;
        follow.turn_id = ctx.active_turn_id;
        follow.prompt = next.prompt;
        follow.author = next.author;
        follow.delivery = .continuation;
        follow.images = &.{};
        follow.authorized_image_catalog = &.{};
        follow.history = history;
        follow.unversioned_history_count = ctx.session.unversionedHistoryEnd();
        debug_trace.eventf("mailbox", "ask_next_turn", .{ .turn_id = ctx.active_turn_id }, "author={s}", .{@tagName(next.author)});
        if (try runAskTurn(&ctx, alloc, options, &deps, semantic_presentation, turn_config, follow)) |early| return early;
    }
    worker_events_drained = true;
    if (ctx.presenter) |value| try value.finish();

    var result = try takePromptRunResult(&ctx, alloc);
    if (goalSnapshot(&ctx)) |snapshot| result.exit_code = goalExitCode(snapshot.status);
    return result;
}

const goal_turn_limit_reason = "stopped after the most turns one request takes (task.print_max_turns)";

const goal_control_words = [_][]const u8{ "pause", "resume", "cancel" };

fn firstWord(text: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, text, " \t\r\n") orelse text.len;
    return text[0..end];
}

fn goalObjectiveFromPrompt(prompt: []const u8) error{GoalObjectiveRequired}!?[]const u8 {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    const command = "/goal";
    if (!std.mem.startsWith(u8, trimmed, command)) return null;
    if (trimmed.len > command.len and !std.ascii.isWhitespace(trimmed[command.len])) return null;
    const args = std.mem.trim(u8, trimmed[command.len..], " \t\r\n");
    if (args.len == 0 or std.mem.eql(u8, args, "status")) return null;
    for (goal_control_words) |word| {
        if (std.mem.eql(u8, args, word)) return null;
    }
    const head = firstWord(args);
    if (std.mem.eql(u8, head, "next")) return null;
    var rest = args;
    if (std.mem.eql(u8, head, "replace")) rest = std.mem.trimStart(u8, args[head.len..], " \t\r\n");
    if (std.mem.eql(u8, firstWord(rest), "--")) rest = std.mem.trimStart(u8, rest[2..], " \t\r\n");
    const objective = std.mem.trim(u8, rest, " \t\r\n");
    if (objective.len == 0) return error.GoalObjectiveRequired;
    return objective;
}

test "goal prompt is a create only for an objective; status, control words and next fall through" {
    try std.testing.expectEqualStrings("Ship it", (try goalObjectiveFromPrompt("/goal Ship it")).?);
    try std.testing.expectEqualStrings("status now", (try goalObjectiveFromPrompt("/goal status now")).?);
    try std.testing.expectEqualStrings("Ship it", (try goalObjectiveFromPrompt("  /goal replace Ship it  ")).?);
    try std.testing.expectEqualStrings("pause", (try goalObjectiveFromPrompt("/goal replace pause")).?);
    try std.testing.expectEqualStrings("pause the rollout", (try goalObjectiveFromPrompt("/goal -- pause the rollout")).?);
    try std.testing.expect((try goalObjectiveFromPrompt("/goal")) == null);
    try std.testing.expect((try goalObjectiveFromPrompt("/goal status")) == null);
    try std.testing.expect((try goalObjectiveFromPrompt("/goal pause")) == null);
    try std.testing.expect((try goalObjectiveFromPrompt("/goal resume")) == null);
    try std.testing.expect((try goalObjectiveFromPrompt("/goal cancel")) == null);
    try std.testing.expect((try goalObjectiveFromPrompt("/goal next Ship it")) == null);
    try std.testing.expect((try goalObjectiveFromPrompt("/goalie Ship it")) == null);
    try std.testing.expect((try goalObjectiveFromPrompt("Ship it /goal")) == null);
    try std.testing.expectError(error.GoalObjectiveRequired, goalObjectiveFromPrompt("/goal replace"));
    try std.testing.expectError(error.GoalObjectiveRequired, goalObjectiveFromPrompt("/goal --"));
}

fn goalSnapshot(ctx: *AskContext) ?goal_state.Snapshot {
    return ctx.goal.snapshot(io_mod.milliTimestamp());
}

fn goalExitCode(status: goal_state.Status) u8 {
    return switch (status) {
        .active, .complete => 0,
        .blocked => 3,
        .paused => 6,
    };
}

fn goalCancelResult(ctx: *AskContext, alloc: Allocator, err: anyerror) !PromptRunResult {
    if (err != error.Cancelled) return err;
    const snapshot = goalSnapshot(ctx) orelse return err;
    if (snapshot.status != .active) return err;
    _ = try ctx.goal.pause(alloc, io_mod.milliTimestamp(), null);
    headless_interrupt.acknowledge();
    var result = try takePromptRunResult(ctx, alloc);
    result.exit_code = goalExitCode(.paused);
    return result;
}

fn runAskTurn(
    ctx: *AskContext,
    alloc: Allocator,
    options: RunOptions,
    deps: *const agent_runtime.AgentRuntimeDeps,
    semantic_presentation: ?agent_runtime.SemanticPresentationSink,
    config: agent_runtime.Config,
    job: worker_runtime.QueuedPrompt,
) !?PromptRunResult {
    options.deps.process_queued_prompt(&ctx.session.agent, deps, semantic_presentation, ctx.lifecycleContext(), config, job) catch |err| {
        if (!options.output_mode.capturesJson()) return err;
        var failed_result = try takePromptRunResult(ctx, alloc);
        failed_result.exit_code = 1;
        failed_result.error_code = @errorName(err);
        return failed_result;
    };
    return null;
}

fn maybeStartAskTitleTask(
    ctx: *AskContext,
    setting_enabled: bool,
    prompt: []const u8,
    fresh_session: bool,
) ?*session_title_generation.Task {
    if (comptime @import("builtin").is_test) return null;
    if (comptime @import("builtin").target.os.tag == .wasi) return null;
    if (!setting_enabled or !fresh_session) return null;
    if (ctx.session.agent.history.items.len != 0) return null;
    const session_id = ctx.activeSessionId() orelse return null;
    const bundle = ctx.cfg.provider_set.select(ctx.provider);
    const title_model = bundle.title_model orelse return null;
    const agent_stream = bundle.agent_stream orelse return null;
    const excerpt = session_title_generation.promptExcerpt(prompt) orelse return null;
    if (ctx.credential_source != .host_managed and ctx.api_key.len == 0) return null;
    const task = session_title_generation.Task.create(.{
        .session_id = session_id,
        .model = title_model,
        .prompt_excerpt = excerpt,
        .api_key = if (ctx.api_key.len > 0) ctx.api_key else null,
        .gateway_team = ctx.gateway_team,
        .account_id = ctx.account_id,
        .credential_source = ctx.credential_source,
        .stream_provider = agent_stream,
    }) catch return null;
    task.spawn() catch |err| {
        debug_trace.logf("session", "event=title_generation result=unavailable reason=spawn err={s}", .{@errorName(err)});
        task.destroy();
        return null;
    };
    return task;
}

fn completeAskTitleTask(ctx: *AskContext, task: *session_title_generation.Task) void {
    defer task.destroy();
    task.joinOrCancel(ctx.cancelFlag(), session_title_generation.after_turn_grace_ms);
    const title = task.takeTitle() orelse return;
    defer std.heap.c_allocator.free(title);
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    if (ctx.v2) |v2| {
        if (!std.mem.eql(u8, v2.id(), task.session_id)) {
            debug_trace.logf("session", "event=title_generation_apply result=dropped reason=session_changed session={s}", .{task.session_id});
            return;
        }
        const installed = v2.installGeneratedTitle(ctx.session.agent.history.items, title) catch |err| {
            debug_trace.logf("session", "event=title_generation_apply result=failed session={s} err={s}", .{ task.session_id, @errorName(err) });
            return;
        };
        if (installed) {
            ctx.session_title.set(ctx.alloc, title) catch {};
            ctx.command_hooks.noteSessionTitle(ctx.alloc, ctx.session_title.get());
            debug_trace.logf("session", "event=title_generation_apply result=installed session={s}", .{task.session_id});
        }
    }
}

fn writeShellSnapshotNotice(ctx: *AskContext) void {
    var buffer: [shell_snapshot.max_notice_bytes]u8 = undefined;
    const notice = shell_snapshot.processOwner().takeUiNotice(&buffer) orelse return;
    ctx.writeStderr("fx ask: warning: ") catch return;
    ctx.writeStderr(notice) catch return;
    ctx.writeStderr("\n") catch return;
}

fn takePromptRunResult(ctx: *AskContext, alloc: Allocator) !PromptRunResult {
    finishThinkingBlock(ctx);
    finishPrintStream(ctx);
    writeShellSnapshotNotice(ctx);
    const assistant_output = try alloc.dupe(u8, ctx.assistant_output.items);
    errdefer alloc.free(assistant_output);
    const final_output: []u8 = if (ctx.final_output.items.len > 0)
        try alloc.dupe(u8, ctx.final_output.items)
    else
        @constCast(&.{});
    errdefer if (final_output.len > 0) alloc.free(final_output);
    const final_source: []u8 = if (ctx.final_source.items.len > 0)
        try alloc.dupe(u8, ctx.final_source.items)
    else
        @constCast(&.{});
    errdefer if (final_source.len > 0) alloc.free(final_source);
    const model = try alloc.dupe(u8, ctx.model);
    errdefer alloc.free(model);
    const resolved_provider: []u8 = if (ctx.resolved_provider) |provider|
        try alloc.dupe(u8, provider)
    else
        @constCast(&.{});
    errdefer if (resolved_provider.len > 0) alloc.free(resolved_provider);
    const session_id = if (ctx.v2) |v2|
        try alloc.dupe(u8, if (v2.saved()) v2.id() else "")
    else
        try alloc.dupe(u8, "");
    errdefer if (session_id.len > 0) alloc.free(session_id);

    const tool_calls = try takeToolCallRecords(ctx, alloc);

    return .{
        .exit_code = if (ctx.failed) 1 else 0,
        .assistant_output = assistant_output,
        .final_output = final_output,
        .final_source = final_source,
        .interrupted = ctx.processInterruptRequested(),
        .output_write_failed = ctx.output_write_failed,
        .output_reader_gone = ctx.output_reader_gone,
        .model = model,
        .resolved_provider = resolved_provider,
        .session_id = session_id,
        .tool_calls = tool_calls,
        .step_count = ctx.step_count,
        .error_code = ctx.typed_error_code,
        .auth_failure = ctx.auth_failure,
        .recovery = ctx.last_recovery_status,
        .usage = ctx.session.agent.turn_usage,
        .blocked_by_limit = ctx.blocked_by_limit,
    };
}

fn takeToolCallRecords(ctx: *AskContext, alloc: Allocator) ![]ToolCallRecord {
    ctx.tool_call_records_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.tool_call_records_mutex.unlock(io_mod.getIo());
    const owned = if (ctx.tool_call_records.items.len > 0)
        try alloc.dupe(ToolCallRecord, ctx.tool_call_records.items)
    else
        @as([]ToolCallRecord, &.{});
    if (owned.len > 0) ctx.tool_call_records.clearRetainingCapacity();
    return owned;
}

fn agentRuntimeDeps(ctx: *AskContext) agent_runtime.AgentRuntimeDeps {
    return .{
        .ctx = @ptrCast(ctx),
        .agent_stream_provider = ctx.agentStreamProvider(),
        .render_assistant_text = ctx.output_mode.isTerminal(),
        .tool_registry = ctx.toolRegistry(),
        .context_registry = ctx.deps.context_registry,
        .context_enabled = ctx.context_enabled,
        .finalize_turn = finalizeTurn,
        .release_agent_terminal_lease = releaseAgentTerminalLease,
        .append_runtime_context = appendRuntimeContext,
        .append_static_context = appendStaticContext,
        .validate_tool_call = validateToolCall,
        .snapshot_mcp_definition = snapshotMcpDefinition,
        .resolve_unselected_mcp_tool = resolveUnselectedMcpTool,
        .prepare_skill_call = prepareSkillCall,
        .check_tool_availability = checkToolAvailability,
        .request_tool_permission = requestToolPermissionOutcomeWithRequest,
        .request_prepared_file_mutation_permission = requestPreparedFileMutationPermissionOutcomeForRuntime,
        .resolve_tool_action_display_target = resolveToolActionDisplayTarget,
        .describe_tool_action = describeToolAction,
        .describe_tool_action_completed = describeToolActionCompleted,
        .describe_tool_action_denied = describeToolActionDenied,
        .permission_target_for_call = permissionTargetForCall,
        .execute_tool_call = executeToolCallAuthorized,
        .publish_committed_file_handoff = publishCommittedFileHandoff,
        .propagate_history_turn = propagateHistoryTurn,
        .commit_context_compaction = .{ .commit = commitContextCompaction },
        .append_turn_piece = if (ctx.v2 != null) appendTurnPiece else null,
        .record_usage = if (ctx.v2 != null) recordUsage else null,
        .save_todos = if (ctx.v2 != null) saveTodos else null,
        .save_prompt_images = if (ctx.v2 != null) savePromptImages else null,
        .propagate_grant = propagateGrant,
        .push_event = pushEvent,
        .push_text = pushText,
        .push_reasoning_delta = if (printsThinking(ctx.output_mode, ctx.deps.invocation)) pushReasoningDelta else null,
        .push_tool_lifecycle = pushToolLifecycle,
        .push_diff_block = pushDiffBlock,
        .push_system_notice = pushSystemNotice,
        .push_context_notice = pushContextNotice,
        .push_route_recovery_status = pushRouteRecoveryStatus,
        .begin_route_recovery_request = beginRouteRecoveryRequest,
        .push_command_output_complete = pushCommandOutputComplete,
        .push_http_error = pushHttpError,
        .refresh_gateway_credential = refreshGatewayCredential,
        .available_model_capabilities = availableModelCapabilities,
        .resolve_model_capabilities = resolveModelCapabilities,
        .model_catalog_failure = modelCatalogFailure,
        .format_tool_execution_error = formatToolExecutionError,
        .record_tool_call_rejected = recordToolCallRejected,
        .record_tool_call_failed = recordToolCallFailed,
    };
}

fn modelCatalogFailure(raw_ctx: *anyopaque) ?model_catalog.FailureCategory {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return ctx.capability_resolver.downFailure();
}

fn releaseAgentTerminalLease(raw_ctx: *anyopaque, session_id: []const u8) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return tool_runtime.release_agent_terminal_lease(ctx.toolContext(), session_id);
}

fn refreshGatewayCredential(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    source: credentials.Source,
    mode: auth_runtime.CredentialRefreshMode,
    expected_account_id: ?[]const u8,
) !?[]u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (mode == .if_needed and auth_runtime.requestPathCredentialVerifiedRecently(source)) {
        debug_trace.logf("auth", "credential refresh skipped source={t} reason=verified_recently", .{source});
        return null;
    }
    var refreshed = (try auth_runtime.refreshCredentialForAccount(
        ctx.cfg.gateway_provider.oauth_transport,
        ctx.alloc,
        source,
        mode,
        expected_account_id,
    )) orelse return null;
    defer refreshed.deinit(ctx.alloc);
    return try adoptRefreshedAskCredential(ctx, alloc, &refreshed);
}

fn adoptRefreshedAskCredential(
    ctx: *AskContext,
    worker_alloc: Allocator,
    refreshed: *credentials.Credential,
) ![]u8 {
    if (ctx.credential_source != refreshed.source) return error.CredentialAuthorityChanged;
    if (!optionalCredentialFieldEqual(ctx.account_id, refreshed.accountId()) or
        !optionalCredentialFieldEqual(ctx.gateway_team, refreshed.gatewayTeam()))
    {
        return error.CredentialAuthorityChanged;
    }

    const worker_token = try worker_alloc.dupe(u8, refreshed.token);
    errdefer secret.zeroAndFree(worker_alloc, worker_token);
    if (ctx.refreshed_credential) |*current| current.deinit(ctx.alloc);
    ctx.refreshed_credential = refreshed.*;
    refreshed.token = &.{};
    refreshed.account_id = null;
    refreshed.team_id = null;
    refreshed.team_slug = null;

    const current = &ctx.refreshed_credential.?;
    ctx.api_key = current.token;
    ctx.credential_source = current.source;
    ctx.account_id = current.accountId();
    ctx.gateway_team = current.gatewayTeam();
    ctx.model_catalog_access = credentials.catalogAccessForCredentialAndAccount(
        current.source,
        current.token,
        current.gatewayTeam(),
        current.accountId(),
    );
    return worker_token;
}

fn optionalCredentialFieldEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn resolveModelCapabilities(raw_ctx: *anyopaque, _: Allocator, model: []const u8) model_capabilities.ResolveError!model_capabilities.Capabilities {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const bundle = ctx.cfg.provider_set.select(ctx.provider);
    const catalog = bundle.model_catalog orelse return bundle.fallbackModelCapabilities(model);
    return ctx.capability_resolver.resolveWithin(
        ctx.alloc,
        catalog,
        .{
            .access = ctx.model_catalog_access,
            .endpoint = ctx.cfg.gateway_models_path,
            .cancel_flag = ctx.cancelFlag(),
        },
        model,
        bundle.fallbackModelCapabilities(model),
        gateway_provider.catalog_connect_wait_ms,
    );
}

fn availableModelCapabilities(raw_ctx: *anyopaque, model: []const u8) model_capabilities.Capabilities {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return ctx.capability_resolver.available(
        model,
        ctx.cfg.provider_set.select(ctx.provider).fallbackModelCapabilities(model),
    );
}

fn resolveModelOverride(raw_ctx: ?*anyopaque, alloc: Allocator, raw_model: []const u8) Allocator.Error!subagent_model_contract.ModelCatalogMatch {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx.?));
    const bundle = ctx.cfg.provider_set.select(ctx.provider);
    const catalog_provider = bundle.model_catalog orelse return .no_catalog;
    _ = ctx.capability_resolver.resolveWithin(
        ctx.alloc,
        catalog_provider,
        .{
            .access = ctx.model_catalog_access,
            .endpoint = ctx.cfg.gateway_models_path,
            .cancel_flag = ctx.cancelFlag(),
        },
        raw_model,
        bundle.fallbackModelCapabilities(raw_model),
        gateway_provider.catalog_connect_wait_ms,
    ) catch return .no_catalog;
    const entries = ctx.capability_resolver.catalogEntries() orelse return .no_catalog;
    var ids = try model_catalog.projectModelIds(alloc, entries);
    defer {
        for (ids.items) |id| alloc.free(id);
        ids.deinit(alloc);
    }
    return subagent_model_contract.matchCatalogModel(alloc, ids.items, raw_model);
}

fn finalizeTurn(raw_ctx: *anyopaque, turn_id: u64, outcome: types.TurnPresentationOutcome, disposition: ?types.ProviderCompletionDisposition) !void {
    std.debug.assert(turn_id != 0);
    _ = disposition;
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (outcome == .failed or outcome == .paused) {
        ctx.failed = true;
    }
    if (outcome == .completed) discard_restarted_json_preview(ctx);
}

fn appendRuntimeContext(raw_ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    try ctx.deps.context_registry.appendDefaultTransient(.{
        .workspace_root = ctx.workspace_root,
        .access_scope = ctx.workspace_access.scope(ctx.workspace_root),
        .interactive = false,
        .permission_mode = ctx.permission_mode,
    }, arena, messages);
}

fn appendStaticContext(raw_ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    try ctx.deps.context_registry.appendDefaultStatic(.{
        .project_context = ctx.modelVisibleProjectContext(),
    }, arena, messages);
    var snapshot = if (ctx.mcp_host) |h|
        try h.catalog.modelSnapshot(arena)
    else
        try mcp_model_catalog.Snapshot.empty(arena);
    defer snapshot.deinit(arena);
    const section = try mcp_model_catalog.render(arena, snapshot);
    if (section.text.len > 0) {
        try messages.append(arena, .{ .role = .system, .content = section.text });
    }
    if (section.notice) |notice| try pushContextNotice(raw_ctx, notice);
}

fn topLevelMcpTools(ctx: *AskContext, arena: Allocator) []const agent_stream_provider.DynamicFunctionTool {
    const h = ctx.mcp_host orelse return &.{};
    const loaded = h.catalog.snapshotAlwaysLoadedTools(arena, ctx.permission_rules, ctx.context_limits, .unrestricted, ctx.cancelFlag()) catch |err| {
        debug_trace.logf("mcp", "top-level MCP tools not loaded for this turn err={s}", .{@errorName(err)});
        return &.{};
    };
    if (loaded.notice) |notice| pushContextNotice(@ptrCast(ctx), notice) catch {};
    const tools = runtime_gateway_step.withSelectedDynamicTools(arena, &.{}, loaded.tools) catch |err| {
        debug_trace.logf("mcp", "top-level MCP tools not advertised for this turn err={s}", .{@errorName(err)});
        return &.{};
    };
    debug_trace.logf("mcp", "advertised top-level MCP tools count={d}", .{tools.len});
    return tools;
}

fn snapshotMcpDefinition(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, known: tool_mcp_runtime.Binding) !tool_mcp_runtime.DefinitionSnapshot {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return tool_runtime.snapshotMcpDefinition(ctx.toolContext(), arena, name, known);
}

fn resolveUnselectedMcpTool(raw_ctx: *anyopaque, arena: Allocator, name: []const u8) !?tool_mcp_runtime.SelectedTool {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return tool_runtime.resolveUnselectedMcpTool(ctx.toolContext(), arena, name);
}

fn validateToolCall(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (try ctx.cfg.mode_registry.toolPolicyDeniedJson(arena, ctx.deps.tool_set, ctx.mode_id, call.name)) |reason| {
        return .{ .failure = reason };
    }
    return tool_runtime.validateToolCall(ctx.toolContext(), arena, call);
}

fn checkToolAvailability(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return tool_runtime.checkToolAvailability(ctx.toolContext(), arena, call);
}

fn prepareSkillCall(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, locations: ?*const skill_contract.Locations) !skill_contract.CallPreparation {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return tool_runtime.prepareSkillCall(ctx.toolContext(), arena, call, locations);
}

fn cliAdmissionContext(
    ctx: *AskContext,
    advertised_dynamic_tool_names: []const []const u8,
    review_turn: ?permission_auto_classifier.ReviewTurnContext,
) tool_runtime.Context {
    var tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(
        ctx.toolContext(),
        advertised_dynamic_tool_names,
    );
    tool_ctx.permission_review_turn = review_turn;
    if (cliContextPermissionPromptAllowed(ctx)) {
        tool_ctx.permission_prompter = .{
            .context = @ptrCast(ctx),
            .request_fn = requestCliPermission,
            .hook_answers = ctx.command_hooks.hookAnswers(),
        };
    }
    return tool_ctx;
}

fn requestPreparedFileMutationPermissionOutcomeForRuntime(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const tool_ctx = cliAdmissionContext(ctx, advertised_dynamic_tool_names, review_turn);
    return finishCliPermissionOutcome(
        ctx,
        tool_ctx,
        arena,
        call,
        permission_mode,
        try tool_admission.requestPreparedFileMutationPermissionOutcome(
            tool_ctx.admissionInputWithLiveAuthority(live_authority),
            arena,
            call,
            prepared,
            permission_mode,
            local_grants,
        ),
    );
}

fn requestToolPermissionOutcome(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, permission_mode: PermissionMode, local_grants: []const PermissionGrant, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const tool_ctx = cliAdmissionContext(ctx, advertised_dynamic_tool_names, null);
    return finishCliPermissionOutcome(
        ctx,
        tool_ctx,
        arena,
        call,
        permission_mode,
        try tool_admission.requestPermissionOutcome(
            tool_ctx.admissionInput(),
            arena,
            call,
            permission_mode,
            local_grants,
        ),
    );
}

fn requestToolPermissionOutcomeWithRequest(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, revalidation: ?agent_runtime.LivePermissionRevalidation, advertised_dynamic_tool_names: []const []const u8, mcp_review_schema_json: ?[]const u8) !command_admission.PermissionOutcome {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    var tool_ctx = cliAdmissionContext(ctx, advertised_dynamic_tool_names, review_turn);
    tool_ctx.mcp_review_schema_json = mcp_review_schema_json;
    return finishCliPermissionOutcome(
        ctx,
        tool_ctx,
        arena,
        call,
        permission_mode,
        if (revalidation) |request| switch (request) {
            .action => |action| try tool_admission.revalidateLiveActionPermissionOutcome(
                tool_ctx.admissionInputWithLiveAuthority(live_authority),
                arena,
                call,
                permission_mode,
                local_grants,
                action.authority,
                action.human_approval,
            ),
        } else try tool_admission.requestPermissionOutcome(
            tool_ctx.admissionInputWithLiveAuthority(live_authority),
            arena,
            call,
            permission_mode,
            local_grants,
        ),
    );
}

fn finishCliPermissionOutcome(
    ctx: *AskContext,
    tool_ctx: tool_runtime.Context,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    outcome: command_admission.PermissionOutcome,
) !command_admission.PermissionOutcome {
    if (outcome.decision != .permission_required) return outcome;
    const label = try tool_presentation.formatPlainAction(arena, .{
        .tool_registry = tool_ctx.tool_registry,
        .call = call,
        .workspace_root = tool_ctx.workspace_root,
    });
    switch (outcome.requirement orelse .approval_required) {
        .configured_rule => try writeBlockedActionGuidance(
            ctx,
            "fx ask: permission required by configured rule",
            label,
            "noninteractive_permission_prompt_unavailable",
            try configuredRuleHint(arena, outcome.rule_reason),
        ),
        .approval_required => try writeBlockedActionGuidance(
            ctx,
            "fx ask: permission required for tool execution in noninteractive mode",
            label,
            "noninteractive_permission_prompt_unavailable",
            if (permission_mode == .auto)
                "fx ask: human approval is required for this action; use the interactive shell to approve it, or add a narrow matching permission rule\n"
            else
                "fx ask: rerun with --auto to run this action without asking, or use the interactive shell to approve it\n",
        ),
    }
    var denied = outcome;
    denied.denial_reason = .permission_required;
    return denied;
}

fn expectNoninteractiveDenial(outcome: command_admission.PermissionOutcome) !void {
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, outcome.decision);
    try std.testing.expectEqual(
        @as(?types.ToolPermissionDenialReason, .permission_required),
        outcome.denial_reason,
    );
}

const TestReviewTurn = struct {
    tool_calls: [1]ToolCall,
    root_messages: [1][]const u8,

    fn init(root_text: []const u8, call: ToolCall) TestReviewTurn {
        return .{
            .tool_calls = .{call},
            .root_messages = .{root_text},
        };
    }

    fn context(self: *const TestReviewTurn) permission_auto_classifier.ReviewTurnContext {
        return .{
            .model = "openai/gpt-5",
            .pending_assistant = .{ .role = .assistant, .tool_calls = &self.tool_calls },
            .target_call_id = self.tool_calls[0].id,
            .origin = .root,
            .trusted_root_context = self.root_messages[0],
        };
    }
};

fn configuredRuleHint(arena: Allocator, rule_reason: ?[]const u8) ![]const u8 {
    const hint = "fx ask: rerun in the interactive shell to approve this action, or add a narrow matching permission rule before retrying\n";
    const reason = rule_reason orelse return hint;
    return std.fmt.allocPrint(arena, "fx ask: configured rule reason: {s}\n{s}", .{ reason, hint });
}

fn writeBlockedActionGuidance(
    ctx: *AskContext,
    headline: []const u8,
    label: []const u8,
    reason: []const u8,
    hint: []const u8,
) !void {
    try ctx.writeLine(headline);
    try ctx.writeStderr("fx ask: blocked action: ");
    try ctx.writeStderr(label);
    try ctx.writeStderr("\nfx ask: reason=");
    try ctx.writeStderr(reason);
    try ctx.writeStderr("\n");
    try ctx.writeStderr(hint);
}

fn requestCliPermission(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    request: permission_request.PermissionRequest,
    _: ToolCall,
    _: ?*const diff_mod.FileReview,
    _: ?[]const PermissionGrant,
) anyerror!permission_request.OwnedPermissionResponse {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return switch (try promptCliPermissionApproval(ctx, request.label)) {
        .approve => permission_request.OwnedPermissionResponse.init(alloc, .once, null),
        .deny => permission_request.OwnedPermissionResponse.init(alloc, .deny, null),
        .unavailable => error.PermissionPromptUnavailable,
    };
}

fn promptCliPermissionApproval(
    ctx: *AskContext,
    label: []const u8,
) !PermissionApprovalPromptResult {
    if (!cliContextPermissionPromptAllowed(ctx)) return .unavailable;
    return try ctx.deps.permission_approval_prompt(
        ctx.deps.permission_approval_prompt_ctx,
        ctx.deps.stderr_ctx,
        ctx.deps.write_stderr,
        label,
        ctx,
        notifyAskPermissionAttention,
    );
}

fn notifyAskPermissionAttention(raw: ?*anyopaque) void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw.?));
    ctx.dispatchAttentionRequired(.permission);
}

fn emitAskNotificationBell(raw: *anyopaque) void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw));
    if (!ctx.deps.stderr_is_tty(ctx.deps.stderr_ctx)) return;
    ctx.writeStderr("\x07") catch |err| {
        debug_trace.logf(
            "notifications",
            "fx ask terminal bell write failed err={s}",
            .{@errorName(err)},
        );
    };
}

fn cliPermissionPromptAllowed(
    output_mode: OutputMode,
    prompt_permissions: bool,
    stdin_is_tty: bool,
) bool {
    return switch (output_mode) {
        .raw, .terminal, .terminal_no_color => true,
        .json, .quiet => prompt_permissions and stdin_is_tty,
    };
}

fn narrowAskTools(arena: Allocator, base: tool_set_contract.ToolSet, tools: ?[]const u8, disallowed: []const []const u8) !tool_set_contract.ToolSet {
    var except: std.ArrayList([]const u8) = .empty;
    for (disallowed) |list| {
        var names = std.mem.tokenizeScalar(u8, list, ',');
        while (names.next()) |name| try except.append(arena, std.mem.trim(u8, name, " "));
    }
    var only: ?[]const []const u8 = null;
    if (tools) |list| {
        var kept: std.ArrayList([]const u8) = .empty;
        var names = std.mem.tokenizeScalar(u8, list, ',');
        while (names.next()) |name| try kept.append(arena, std.mem.trim(u8, name, " "));
        only = kept.items;
    }
    const filter: tool_set_contract.NameFilter = .{ .only = only, .except = except.items };
    return (try tool_set_contract.narrow(arena, base, filter)) orelse base;
}

fn appendAllowedTools(alloc: Allocator, set: *types.PermissionRuleSet, lists: []const []const u8) !void {
    if (lists.len == 0) return;
    var added = try config_runtime.allowRulesFromToolLists(alloc, lists);
    errdefer added.deinit(alloc);
    if (added.rules.len == 0) return;
    const merged = try alloc.alloc(types.PermissionRule, set.rules.len + added.rules.len);
    @memcpy(merged[0..set.rules.len], set.rules);
    @memcpy(merged[set.rules.len..], added.rules);
    if (set.rules.len > 0) alloc.free(set.rules);
    alloc.free(added.rules);
    set.rules = merged;
}

test "--permission-prompts none denies what would prompt and host keeps the mode" {
    const alloc = std.testing.allocator;
    var denied = try parseOptionsWithStdin(alloc, &.{ "--permission-prompts", "none", "hello" }, .tty);
    defer denied.deinit(alloc);
    try std.testing.expectEqual(@as(?PermissionMode, .dontAsk), denied.agent.permission);

    var hosted = try parseOptionsWithStdin(alloc, &.{ "--auto", "--permission-prompts", "host", "hello" }, .tty);
    defer hosted.deinit(alloc);
    try std.testing.expectEqual(@as(?PermissionMode, .auto), hosted.agent.permission);

    try std.testing.expectError(error.InvalidAskArgs, parseOptionsWithStdin(alloc, &.{ "--permission-prompts", "sometimes", "hello" }, .tty));
}

test "allowed tools given on the command line join the saved permission rules as allow rules" {
    const alloc = std.testing.allocator;
    var set = try config_runtime.allowRulesFromToolLists(alloc, &.{"Read"});
    defer set.deinit(alloc);
    try appendAllowedTools(alloc, &set, &.{ "Bash(npm test)", "Grep,Glob" });
    try std.testing.expectEqual(@as(usize, 4), set.rules.len);
    try std.testing.expectEqualStrings("Read", set.rules[0].permission);
    try std.testing.expectEqualStrings("Bash", set.rules[1].permission);
    try std.testing.expectEqualStrings("npm test", set.rules[1].pattern);
    try std.testing.expectEqualStrings("Glob", set.rules[3].permission);

    var empty: types.PermissionRuleSet = .{};
    defer empty.deinit(alloc);
    try appendAllowedTools(alloc, &empty, &.{});
    try std.testing.expectEqual(@as(usize, 0), empty.rules.len);

    var options = try parseOptionsWithStdin(alloc, &.{ "--allowed-tools", "Read,Bash(npm test)", "--allowedTools", "Grep", "hello" }, .tty);
    defer options.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), options.allowed_tools.items.len);
    try std.testing.expectError(error.InvalidAskArgs, parseOptionsWithStdin(alloc, &.{ "--allowed-tools", "Bash(npm test", "hello" }, .tty));
}

test "--tools and --disallowedTools narrow the tool set the request sees" {
    const alloc = std.testing.allocator;
    var options = try parseOptionsWithStdin(alloc, &.{ "--tools", "read_file,Agent", "--disallowedTools", "Agent", "--disallowed-tools", "write_file", "hello" }, .tty);
    defer options.deinit(alloc);
    try std.testing.expectEqualStrings("read_file,Agent", options.tools.?);
    try std.testing.expectEqual(@as(usize, 2), options.disallowed_tools.items.len);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tools: [3]tool_dispatch.Tool = undefined;
    for (&tools, [_][]const u8{ "read_file", "write_file", "Agent" }) |*tool, name| tool.name = name;
    var base = tool_set_contract.empty;
    base.registry.tools = &tools;
    base.order = &.{ "read_file", "write_file", "Agent" };

    const narrowed = try narrowAskTools(arena, base, options.tools, options.disallowed_tools.items);
    try std.testing.expectEqual(@as(usize, 1), narrowed.registry.tools.len);
    try std.testing.expect(narrowed.registry.lookup("read_file") != null);
    try std.testing.expectEqual(@as(usize, 1), narrowed.order.len);

    const untouched = try narrowAskTools(arena, base, null, &.{});
    try std.testing.expectEqual(@as(usize, 3), untouched.registry.tools.len);
}

fn bareDiscovery(bare: bool, discovered: bool) bool {
    return discovered and !bare;
}

test "bare mode turns off every discovery a request would otherwise run" {
    try std.testing.expect(bareDiscovery(false, true));
    try std.testing.expect(!bareDiscovery(true, true));
    try std.testing.expect(!bareDiscovery(false, false));
    var options = try parseOptionsWithStdin(std.testing.allocator, &.{ "--bare", "hello" }, .tty);
    defer options.deinit(std.testing.allocator);
    try std.testing.expect(options.bare);
    var plain = try parseOptionsWithStdin(std.testing.allocator, &.{"hello"}, .tty);
    defer plain.deinit(std.testing.allocator);
    try std.testing.expect(!plain.bare);
}

fn cliContextPermissionPromptAllowed(ctx: *const AskContext) bool {
    return cliPermissionPromptAllowed(
        ctx.output_mode,
        ctx.prompt_permissions,
        ctx.deps.stdin_is_tty(ctx.deps.stdin_ctx),
    );
}

fn describeToolAction(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .workspace_root = ctx.workspace_root,
        .display_target = display_target,
        .is_available_dynamic_mcp_tool = lifecycleDynamicMcpToolAvailable(ctx, call.name, advertised_dynamic_tool_names),
    });
}

fn resolveToolActionDisplayTarget(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return tool_presentation.resolveTerminalDisplayTarget(
        arena,
        ctx.toolRegistry(),
        ctx.workspace_root,
        &ctx.terminal_client,
        &ctx.managed_executions,
        call,
    );
}

fn describeToolActionCompleted(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (try tool_presentation.formatSubagentPlainAction(arena, call, .completed)) |line| return line;
    return tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .workspace_root = ctx.workspace_root,
        .display_target = display_target,
        .is_available_dynamic_mcp_tool = lifecycleDynamicMcpToolAvailable(ctx, call.name, advertised_dynamic_tool_names),
    });
}

fn describeToolActionDenied(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (try tool_presentation.formatSubagentPlainAction(arena, call, .{ .stopped = label })) |line| return line;
    const action = try tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .workspace_root = ctx.workspace_root,
        .display_target = display_target,
        .is_available_dynamic_mcp_tool = lifecycleDynamicMcpToolAvailable(ctx, call.name, advertised_dynamic_tool_names),
    });
    return arena.print("{s}: {s}", .{ label, action });
}

fn lifecycleDynamicMcpToolAvailable(ctx: *AskContext, name: []const u8, advertised_dynamic_tool_names: []const []const u8) bool {
    const capability = lifecycleDynamicMcpAvailability(ctx);
    return dynamicMcpToolAvailable(ctx.toolRegistry(), name, advertised_dynamic_tool_names, capability.context, capability.has_tool, capability.access);
}

fn lifecycleDynamicMcpAvailability(ctx: *AskContext) tool_mcp_runtime.RuntimeCapabilities {
    if (ctx.mcp_host) |h| return h.catalog.runtimeCapabilities();
    return .{};
}

fn dynamicMcpToolAvailable(registry: tool_dispatch.Registry, name: []const u8, advertised_dynamic_tool_names: []const []const u8, mcp_ctx: ?*anyopaque, has_tool: ?McpHasToolFn, access: tool_mcp_runtime.Access) bool {
    if (!tool_presentation.isAdvertisedDynamicMcpName(registry, name, advertised_dynamic_tool_names)) return false;
    const raw_ctx = mcp_ctx orelse return false;
    const has = has_tool orelse return false;
    return has(raw_ctx, name, access);
}

fn permissionTargetForCall(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(
        ctx.toolContext(),
        advertised_dynamic_tool_names,
    );
    return tool_admission.permissionTargetForCall(tool_ctx.admissionInput(), arena, call);
}

fn executeToolCallAuthorized(
    raw_ctx: *anyopaque,
    request: agent_runtime.ToolExecutionRequest,
) !ToolExecutionResult {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    streamNoteToolCall(ctx, request.call);
    var tool_ctx = ctx.toolContext();
    tool_ctx.root_user_intent_context = request.root_user_intent_context;
    tool_ctx.root_user_messages = request.root_user_messages;
    tool_ctx.root_user_evidence_complete = request.root_user_evidence_complete;
    tool_ctx.session_grants = request.session_grants;
    tool_ctx.advertised_dynamic_tool_names = request.advertised_dynamic_tool_names;
    tool_ctx.max_tool_result_bytes = request.max_tool_result_bytes;
    const result = tool_runtime.executeToolCallAuthorized(
        tool_ctx,
        request,
    ) catch |err| {
        captureToolExecutionError(ctx, request, err);
        return err;
    };
    captureToolExecutionResult(ctx, request, result);
    return result;
}

fn captureToolExecutionError(
    ctx: *AskContext,
    request: agent_runtime.ToolExecutionRequest,
    err: anyerror,
) void {
    if (ctx.output_mode.capturesJson()) {
        appendToolCallRecordBestEffort(
            ctx,
            request.call,
            "error",
            null,
            .runtime_failed,
            @errorName(err),
        );
    }
    streamToolResult(ctx, request.call.id, @errorName(err));
}

fn captureToolExecutionResult(
    ctx: *AskContext,
    request: agent_runtime.ToolExecutionRequest,
    result: ToolExecutionResult,
) void {
    if (ctx.output_mode.capturesJson()) {
        appendToolCallRecordBestEffort(
            ctx,
            request.call,
            if (result.status == .failure) "error" else "success",
            result,
            if (result.status == .failure)
                if (result.command_result_json != null) .command_failed else .tool_failed
            else
                null,
            null,
        );
    }
    streamToolResult(ctx, request.call.id, result.model_output);
    if (result.status == .failure and result.finish_turn) {
        ctx.failed = true;
        ctx.typed_error_code = result.status_detail;
    }
}

fn publishCommittedFileHandoff(
    _: *anyopaque,
    _: file_mutation.CommittedFileHandoff,
) agent_runtime.SecondaryPublicationReport {
    return .{ .diff = .skipped, .tracker = .skipped };
}

fn recordToolCallRejected(
    raw_ctx: *anyopaque,
    _: Allocator,
    call: ToolCall,
    model_output: []const u8,
    command_result_json: ?[]const u8,
) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (!ctx.output_mode.capturesJson()) return;
    appendToolCallRecordBestEffort(
        ctx,
        call,
        "error",
        .{
            .status = .failure,
            .model_output = model_output,
            .command_result_json = command_result_json,
        },
        .rejected,
        "rejected",
    );
    streamNoteToolCall(ctx, call);
    streamToolResult(ctx, call.id, model_output);
}

fn recordToolCallFailed(
    raw_ctx: *anyopaque,
    _: Allocator,
    call: ToolCall,
    model_output: []const u8,
    command_result_json: ?[]const u8,
) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (!ctx.output_mode.capturesJson()) return;
    appendToolCallRecordBestEffort(
        ctx,
        call,
        "error",
        .{
            .status = .failure,
            .model_output = model_output,
            .command_result_json = command_result_json,
        },
        .tool_failed,
        "tool_failed",
    );
    streamNoteToolCall(ctx, call);
    streamToolResult(ctx, call.id, model_output);
}

fn appendToolCallRecordBestEffort(
    ctx: *AskContext,
    call: ToolCall,
    status: []const u8,
    result: ?ToolExecutionResult,
    error_category: ?workspace_diagnostics.ToolCallOutcome,
    error_code: ?[]const u8,
) void {
    appendToolCallRecord(
        ctx,
        call,
        status,
        result,
        error_category,
        error_code,
    ) catch |err| {
        debug_trace.logf(
            "cli_ask",
            "tool-call capture dropped name={s} status={s} err={s}",
            .{ call.name, status, @errorName(err) },
        );
    };
}

fn appendToolCallRecord(
    ctx: *AskContext,
    call: ToolCall,
    status: []const u8,
    result: ?ToolExecutionResult,
    error_category: ?workspace_diagnostics.ToolCallOutcome,
    explicit_error_code: ?[]const u8,
) !void {
    ctx.tool_call_records_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.tool_call_records_mutex.unlock(io_mod.getIo());

    const name = try ctx.alloc.dupe(u8, call.name);
    errdefer ctx.alloc.free(name);
    const owned_status = try ctx.alloc.dupe(u8, status);
    errdefer ctx.alloc.free(owned_status);
    var scratch_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const is_shell = std.mem.eql(u8, call.name, "Bash");
    const error_code = if (is_shell and error_category != null)
        try ctx.alloc.dupe(
            u8,
            explicit_error_code orelse shell_failure_code(
                scratch,
                error_category.?,
                result,
            ),
        )
    else
        null;
    errdefer if (error_code) |code| ctx.alloc.free(code);
    const command_result_json = if (result) |execution|
        if (execution.command_result_json) |json|
            try ctx.alloc.dupe(u8, json)
        else
            null
    else
        null;
    errdefer if (command_result_json) |json| ctx.alloc.free(json);
    const ask_question_text = try questionTextForAskCall(ctx.alloc, call);
    errdefer if (ask_question_text) |text| ctx.alloc.free(text);

    try ctx.tool_call_records.append(ctx.alloc, .{
        .name = name,
        .status = owned_status,
        .error_category = if (is_shell) error_category else null,
        .error_code = error_code,
        .command_result_json = command_result_json,
        .ask_question_text = ask_question_text,
        .web_search_completion = if (result) |execution| execution.web_search_completion else null,
        .web_fetch_completion = if (result) |execution| execution.web_fetch_completion else null,
    });
}

fn shell_failure_code(
    arena: Allocator,
    category: workspace_diagnostics.ToolCallOutcome,
    result: ?ToolExecutionResult,
) []const u8 {
    return switch (category) {
        .succeeded => "tool_failed",
        .rejected => "rejected",
        .runtime_failed => "runtime_failed",
        .command_failed => command_failure_code(arena, result),
        .tool_failed => shell_tool_failure_code(arena, result),
    };
}

fn command_failure_code(
    arena: Allocator,
    result: ?ToolExecutionResult,
) []const u8 {
    const json = (result orelse return "command_failed").command_result_json orelse
        return "command_failed";
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch
        return "command_failed";
    const object = switch (parsed) {
        .object => |value| value,
        else => return "command_failed",
    };
    if (json_bool(object, "termination_indeterminate")) return "termination_indeterminate";
    if (json_bool(object, "output_incomplete")) return "output_incomplete";
    if (json_bool(object, "timed_out")) return "timeout";
    if (json_has_value(object, "signal")) return "signal";
    if (json_nonzero_int(object, "exit_code")) return "nonzero_exit";
    return "command_failed";
}

fn shell_tool_failure_code(
    arena: Allocator,
    result: ?ToolExecutionResult,
) []const u8 {
    const body = (result orelse return "tool_failed").model_output;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
        return "tool_failed";
    const root = switch (parsed) {
        .object => |value| value,
        else => return "tool_failed",
    };
    const failure = switch (root.get("error") orelse return "tool_failed") {
        .object => |value| value,
        else => return "tool_failed",
    };
    const tool = switch (failure.get("tool") orelse return "tool_failed") {
        .string => |value| value,
        else => return "tool_failed",
    };
    if (!std.mem.eql(u8, tool, "Bash")) return "tool_failed";
    const code = switch (failure.get("code") orelse return "tool_failed") {
        .string => |value| value,
        else => return "tool_failed",
    };
    if (!safe_error_code(code)) return "tool_failed";
    return code;
}

fn safe_error_code(code: []const u8) bool {
    if (code.len == 0 or code.len > 64) return false;
    for (code) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

fn json_bool(object: std.json.ObjectMap, name: []const u8) bool {
    return switch (object.get(name) orelse return false) {
        .bool => |value| value,
        else => false,
    };
}

fn json_has_value(object: std.json.ObjectMap, name: []const u8) bool {
    return switch (object.get(name) orelse return false) {
        .null => false,
        else => true,
    };
}

fn json_nonzero_int(object: std.json.ObjectMap, name: []const u8) bool {
    return switch (object.get(name) orelse return false) {
        .integer => |value| value != 0,
        else => false,
    };
}

fn questionTextForAskCall(alloc: Allocator, call: ToolCall) !?[]u8 {
    if (!std.mem.eql(u8, call.name, "AskUserQuestion")) return null;
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        call.arguments_json,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const questions_value = parsed.value.object.get("questions") orelse return null;
    if (questions_value != .array or questions_value.array.items.len == 0) return null;
    const first = questions_value.array.items[0];
    if (first != .object) return null;
    const question_value = first.object.get("question") orelse return null;
    if (question_value != .string) return null;
    const text = std.mem.trim(u8, question_value.string, " \t\r\n");
    if (text.len == 0) return null;
    const max_question_text_bytes: usize = 256;
    return try alloc.dupe(
        u8,
        text_utils.utf8PrefixByBytes(text, max_question_text_bytes),
    );
}

fn propagateHistoryTurn(raw_ctx: *anyopaque, turn: HistoryTurn) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    var prepared = try ctx.session.prepareHistoryEntry(ctx.alloc, turn);
    var prepared_owned = true;
    defer if (prepared_owned) types.freeHistoryTurn(ctx.alloc, prepared);
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    if (ctx.v2) |v2| {
        try v2.prepareTurn(&prepared);
        v2.commitTurn(prepared, ctx.session.languageSnapshot()) catch |err| {
            if (session_adapter.writeMayHaveLanded(err)) ctx.prompt_snapshot_committed = true;
            return err;
        };
        ctx.session.commitPreparedHistoryEntry(ctx.alloc, prepared);
        prepared_owned = false;
        ctx.prompt_snapshot_committed = true;
        return;
    }

    ctx.session.commitPreparedHistoryEntry(ctx.alloc, prepared);
    prepared_owned = false;
}

fn commitContextCompaction(
    raw_ctx: *anyopaque,
    summary: types.CompactedSummaryHistoryTurn,
    active_prefix: ?types.AssistantHistoryTurn,
    retained_from: ?types.ContextHistoryCut,
) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    const prepared = try session_runtime.prepareCompactedHistory(ctx.alloc, ctx.session.agent.history.items, summary, retained_from orelse .{ .turns = history_range.rawHistoryTurnCount(ctx.session.agent.history.items) });
    errdefer types.freeHistoryTurnSlice(ctx.alloc, prepared);
    if (ctx.v2) |v2| {
        try v2.commitCompaction(summary, active_prefix != null, retained_from);
        if (active_prefix != null) ctx.prompt_snapshot_committed = true;
    }
    ctx.session.commitCompactedHistory(ctx.alloc, prepared);
}

fn appendTurnPiece(raw_ctx: *anyopaque, progress: agent_runtime.TurnProgress) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    const v2 = ctx.v2 orelse return;
    v2.appendProgress(progress.user, progress.execution, .{ .calls = progress.running_calls, .assistant = progress.running_assistant }) catch |err| {
        debug_trace.logf("session", "event=sessions_v2_stream_failed session={s} err={s} deferred=commit", .{ v2.id(), @errorName(err) });
        return;
    };

    ctx.prompt_snapshot_committed = true;
}

fn recordUsage(raw_ctx: *anyopaque, usage: types.Usage) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    const v2 = ctx.v2 orelse return;
    try v2.recordUsage(usage);
}

fn saveTodos(raw_ctx: *anyopaque, json: []const u8) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    const v2 = ctx.v2 orelse return;
    v2.setTodos(json) catch |err| {
        debug_trace.logf("session", "event=sessions_v2_todos_unsaved session={s} err={s}", .{ v2.id(), @errorName(err) });
    };
}

fn savePromptImages(raw_ctx: *anyopaque, alloc: std.mem.Allocator, images: []types.ImageAttachment) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    const v2 = ctx.v2 orelse return;
    v2.savePromptImages(alloc, images) catch |err| {
        debug_trace.logf("session", "event=sessions_v2_prompt_images_inline session={s} err={s}", .{ v2.id(), @errorName(err) });
    };
}

fn propagateGrant(_: *anyopaque, _: []const u8, _: []const u8) !void {}

fn pushEvent(raw_ctx: *anyopaque, event: WorkerEvent) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    defer worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
    switch (event) {
        .clear_route_recovery_status => {
            ctx.last_recovery_status = null;
            ctx.last_recovery_notice_kind = null;
        },
        .provider_resolved => |slug| {
            if (ctx.resolved_provider) |old| ctx.alloc.free(old);
            ctx.resolved_provider = try ctx.alloc.dupe(u8, slug);
        },
        .finish_prompt => |finished| {
            finishPrintStream(ctx);
            ctx.final_output.clearRetainingCapacity();
            ctx.final_source.clearRetainingCapacity();
            if (finished.terminal_outcome == .completed) switch (finished.turn) {
                .assistant => |turn| {
                    const presentation = @import("../agent/runtime/assistant_stream.zig");
                    const text = finished.presentation_text orelse turn.assistant;
                    const normalized = try presentation.normalizeAssistantTextForDisplay(ctx.alloc, text);
                    defer ctx.alloc.free(normalized);
                    try ctx.final_output.appendSlice(ctx.alloc, presentation.textForCompletedPresentation(text, normalized));
                    try ctx.final_source.appendSlice(ctx.alloc, turn.assistant);
                },
                .compacted_summary, .interrupted => {},
            };
        },
        else => {},
    }
}

fn pushText(raw_ctx: *anyopaque, emission: agent_runtime.TextEmission) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    switch (emission) {
        .assistant_started => {
            discard_restarted_json_preview(ctx);
            ctx.response_output_start = ctx.assistant_output.items.len;
            streamBeginResponse(ctx);
        },
        .assistant_restarted => |text| switch (ctx.output_mode) {
            .raw => try writeRawAssistantBytes(ctx, text),
            .json => {
                ctx.response_restart_pending = true;
                try ctx.writeStderr(text);
            },
            .quiet => try ctx.writeStderr(text),
            .terminal, .terminal_no_color => try ctx.presenter.?.pushText(text),
        },
        .assistant_source => |text| switch (ctx.output_mode) {
            .raw, .json => try pushRawAssistantText(ctx, text),
            .quiet, .terminal, .terminal_no_color => {},
        },
        .assistant_rendered => |text| switch (ctx.output_mode) {
            .terminal, .terminal_no_color => try ctx.presenter.?.pushText(text),
            .quiet, .json, .raw => {},
        },
        .operational => |text| switch (ctx.output_mode) {
            .terminal, .terminal_no_color => try ctx.presenter.?.pushText(text),
            .quiet, .json, .raw => try ctx.writeStderr(text),
        },
    }
}

fn discard_restarted_json_preview(ctx: *AskContext) void {
    if (!ctx.response_restart_pending) return;
    debug_trace.logf("agent", "discarding interrupted JSON preview bytes={d}", .{ctx.assistant_output.items.len - ctx.response_output_start});
    ctx.assistant_output.shrinkRetainingCapacity(ctx.response_output_start);
    streamRestartResponse(ctx);
    ctx.response_restart_pending = false;
    ctx.raw_has_output = ctx.assistant_output.items.len > 0;
    ctx.raw_boundary_pending = ctx.raw_has_output;
    ctx.raw_trailing_newlines = if (std.mem.endsWith(u8, ctx.assistant_output.items, "\n\n"))
        2
    else if (std.mem.endsWith(u8, ctx.assistant_output.items, "\n"))
        1
    else
        0;
}

fn pushRawAssistantText(ctx: *AskContext, text: []const u8) !void {
    if (text.len == 0) return;
    finishThinkingBlock(ctx);
    if (ctx.raw_boundary_pending and ctx.raw_has_output) {
        const separator = if (ctx.raw_trailing_newlines >= 2)
            ""
        else if (ctx.raw_trailing_newlines == 1)
            "\n"
        else
            "\n\n";
        try writeRawAssistantBytes(ctx, separator);
    }
    ctx.raw_boundary_pending = false;
    try writeRawAssistantBytes(ctx, text);
}

fn writeRawAssistantBytes(ctx: *AskContext, text: []const u8) !void {
    if (ctx.output_mode == .json) try ctx.assistant_output.appendSlice(ctx.alloc, text);
    if (ctx.output_mode == .json) try streamAssistantText(ctx, text);
    if (ctx.output_mode == .raw) try ctx.writeStdout(text);
    if (text.len == 0) return;
    ctx.raw_has_output = true;
    var trailing: usize = 0;
    while (trailing < text.len and text[text.len - trailing - 1] == '\n') : (trailing += 1) {}
    ctx.raw_trailing_newlines = if (trailing == text.len)
        @min(2, ctx.raw_trailing_newlines + @as(u8, @intCast(@min(trailing, 2))))
    else
        @intCast(@min(trailing, 2));
}

fn printsThinking(output_mode: OutputMode, invocation: Invocation) bool {
    return output_mode == .raw and invocation == .prompt_flag;
}

fn pushReasoningDelta(raw_ctx: *anyopaque, delta: []const u8) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    var out: std.Io.Writer.Allocating = .init(ctx.alloc);
    defer out.deinit();
    try ctx.thinking_block.write(&out.writer, delta);
    try ctx.writeStderr(out.written());
}

fn finishThinkingBlock(ctx: *AskContext) void {
    if (!ctx.thinking_block.started) return;
    var out: std.Io.Writer.Allocating = .init(ctx.alloc);
    defer out.deinit();
    ctx.thinking_block.finish(&out.writer) catch return;
    ctx.writeStderr(out.written()) catch {};
}

fn streamBeginResponse(ctx: *AskContext) void {
    ctx.print_stream_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.print_stream_mutex.unlock(io_mod.getIo());
    if (ctx.print_stream) |*stream| stream.beginResponse();
}

fn streamRestartResponse(ctx: *AskContext) void {
    ctx.print_stream_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.print_stream_mutex.unlock(io_mod.getIo());
    if (ctx.print_stream) |*stream| stream.restartResponse();
}

fn streamAssistantText(ctx: *AskContext, text: []const u8) !void {
    ctx.print_stream_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.print_stream_mutex.unlock(io_mod.getIo());
    if (ctx.print_stream) |*stream| try stream.appendAssistantText(text);
}

fn streamNoteToolCall(ctx: *AskContext, call: ToolCall) void {
    ctx.print_stream_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.print_stream_mutex.unlock(io_mod.getIo());
    const stream = if (ctx.print_stream) |*value| value else return;
    stream.noteToolCall(call.id, call.name, call.arguments_json) catch |err| {
        debug_trace.logf("cli_ask", "stream-json tool call dropped name={s} err={s}", .{ call.name, @errorName(err) });
    };
}

fn streamToolResult(ctx: *AskContext, call_id: []const u8, content: []const u8) void {
    ctx.print_stream_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.print_stream_mutex.unlock(io_mod.getIo());
    const stream = if (ctx.print_stream) |*value| value else return;
    var out: std.Io.Writer.Allocating = .init(ctx.alloc);
    defer out.deinit();
    stream.writeToolResult(&out.writer, call_id, content) catch |err| {
        debug_trace.logf("cli_ask", "stream-json tool result dropped call_id={s} err={s}", .{ call_id, @errorName(err) });
        return;
    };
    writeStreamLines(ctx, out.written());
}

fn streamRetrying(ctx: *AskContext, status: types.RouteRecoveryStatus) void {
    ctx.print_stream_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.print_stream_mutex.unlock(io_mod.getIo());
    if (ctx.print_stream == null) return;
    var label_buf: [types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
    var out: std.Io.Writer.Allocating = .init(ctx.alloc);
    defer out.deinit();
    print_stream.writeRetrying(&out.writer, status.attempt, status.label(&label_buf)) catch return;
    writeStreamLines(ctx, out.written());
}

fn finishPrintStream(ctx: *AskContext) void {
    ctx.print_stream_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.print_stream_mutex.unlock(io_mod.getIo());
    const stream = if (ctx.print_stream) |*value| value else return;
    var out: std.Io.Writer.Allocating = .init(ctx.alloc);
    defer out.deinit();
    stream.flushAssistant(&out.writer) catch return;
    writeStreamLines(ctx, out.written());
}

fn writeStreamLines(ctx: *AskContext, lines: []const u8) void {
    if (lines.len == 0) return;
    ctx.writeStdout(lines) catch |err| {
        debug_trace.logf("cli_ask", "stream-json write failed err={s}", .{@errorName(err)});
    };
}

fn pushToolLifecycle(raw_ctx: *anyopaque, event: types.ToolLifecycleEvent) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.output_mode.isTerminal()) {
        try ctx.presenter.?.pushToolLifecycle(event);
    }
    switch (event) {
        .provisional => |provisional| if (!ctx.output_mode.isTerminal()) {
            if (provisional.tool_name) |tool_name| {
                try beginPendingToolProgress(ctx, provisional.id.call_id, tool_name);
            }
        },
        .authoritative_started => |started| {
            finishThinkingBlock(ctx);
            ctx.step_count += 1;
            if (!ctx.output_mode.isTerminal()) {
                try beginPendingToolProgress(ctx, started.id.call_id, started.tool_name);
            }
            if (ctx.raw_has_output) ctx.raw_boundary_pending = true;
        },
        .progress => |progress| if (!ctx.output_mode.isTerminal()) {
            try publishPendingToolProgress(ctx, progress.id.call_id, progress.text);
        },
        .turn_finished => if (!ctx.output_mode.isTerminal()) clearPendingToolProgress(ctx),
        .terminal => |value| {
            if (!ctx.output_mode.isTerminal()) {
                try settlePendingToolProgress(ctx, value.id.call_id, value.outcome);
            }

            writeShellSnapshotNotice(ctx);
        },
    }
}

fn beginPendingToolProgress(ctx: *AskContext, call_id: []const u8, tool_name: []const u8) !void {
    ctx.pending_tool_progress_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.pending_tool_progress_mutex.unlock(io_mod.getIo());
    discardPendingToolProgressLocked(ctx, call_id);

    const owned_id = try ctx.alloc.dupe(u8, call_id);
    errdefer ctx.alloc.free(owned_id);
    const owned_name = try ctx.alloc.dupe(u8, tool_name);
    errdefer ctx.alloc.free(owned_name);
    try ctx.pending_tool_progress.append(ctx.alloc, .{
        .call_id = owned_id,
        .tool_name = owned_name,
    });
}

fn publishPendingToolProgress(ctx: *AskContext, call_id: []const u8, text: []const u8) !void {
    ctx.pending_tool_progress_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.pending_tool_progress_mutex.unlock(io_mod.getIo());

    const pending = findPendingToolProgressLocked(ctx, call_id) orelse return;
    const owned_text = try ctx.alloc.dupe(u8, text);
    if (pending.text) |previous| ctx.alloc.free(previous);
    pending.text = owned_text;
    pending.visible = false;
    if (ctx.toolRegistry().lookup(pending.tool_name)) |tool| {
        if (tool.executor_kind == .web_fetch) return;
    }
    if (consumeDeferredToolProgressLocked(ctx, text)) {
        pending.visible = true;
        return;
    }
    try ctx.writeStderr(text);
    try ctx.writeStderr("\n");
    pending.visible = true;
}

fn settlePendingToolProgress(ctx: *AskContext, call_id: []const u8, outcome: types.ToolOutcome) !void {
    ctx.pending_tool_progress_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.pending_tool_progress_mutex.unlock(io_mod.getIo());
    var pending = takePendingToolProgressLocked(ctx, call_id) orelse return;
    defer pending.deinit(ctx.alloc);
    const context_deferred = outcome.kind == .deferred and
        std.mem.startsWith(u8, outcome.summary, types.context_deferred_tool_status_label ++ " ");
    const legacy_deferred = outcome.kind == .denied and
        std.mem.startsWith(u8, outcome.summary, types.deferred_tool_result_output ++ ": ");
    if (!context_deferred and !legacy_deferred) return;
    if (!pending.visible) return;
    const text = pending.text orelse return;
    try ctx.deferred_tool_progress.append(ctx.alloc, text);
    pending.text = null;
}

fn discardPendingToolProgressLocked(ctx: *AskContext, call_id: []const u8) void {
    for (ctx.pending_tool_progress.items, 0..) |pending, index| {
        if (!std.mem.eql(u8, pending.call_id, call_id)) continue;
        const removed = ctx.pending_tool_progress.swapRemove(index);
        removed.deinit(ctx.alloc);
        return;
    }
}

fn takePendingToolProgressLocked(ctx: *AskContext, call_id: []const u8) ?PendingToolProgress {
    for (ctx.pending_tool_progress.items, 0..) |pending, index| {
        if (std.mem.eql(u8, pending.call_id, call_id)) {
            return ctx.pending_tool_progress.swapRemove(index);
        }
    }
    return null;
}

fn findPendingToolProgressLocked(ctx: *AskContext, call_id: []const u8) ?*PendingToolProgress {
    for (ctx.pending_tool_progress.items) |*pending| {
        if (std.mem.eql(u8, pending.call_id, call_id)) return pending;
    }
    return null;
}

fn consumeDeferredToolProgressLocked(ctx: *AskContext, text: []const u8) bool {
    for (ctx.deferred_tool_progress.items, 0..) |progress, index| {
        if (!std.mem.eql(u8, progress, text)) continue;
        ctx.alloc.free(ctx.deferred_tool_progress.swapRemove(index));
        return true;
    }
    return false;
}

fn clearPendingToolProgress(ctx: *AskContext) void {
    ctx.pending_tool_progress_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.pending_tool_progress_mutex.unlock(io_mod.getIo());
    for (ctx.pending_tool_progress.items) |progress| progress.deinit(ctx.alloc);
    ctx.pending_tool_progress.clearRetainingCapacity();
    for (ctx.deferred_tool_progress.items) |progress| ctx.alloc.free(progress);
    ctx.deferred_tool_progress.clearRetainingCapacity();
}

fn onWebSearchProgress(raw_ctx: *anyopaque, _: []const u8, progress: types.WebSearchProgress) void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.output_mode.isTerminal()) return;
    const alloc = std.heap.c_allocator;
    const line = tool_presentation.formatWebSearchProgressPlain(alloc, progress) catch return;
    defer alloc.free(line);
    ctx.web_search_progress_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.web_search_progress_mutex.unlock(io_mod.getIo());
    ctx.writeLine(line) catch {};
}

fn onWebFetchProgress(raw_ctx: *anyopaque, _: []const u8, progress: types.WebFetchProgress) void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.output_mode.isTerminal()) return;
    const alloc = std.heap.c_allocator;
    const line = tool_presentation.formatWebFetchProgressPlain(alloc, progress) catch return;
    defer alloc.free(line);
    ctx.web_search_progress_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.web_search_progress_mutex.unlock(io_mod.getIo());
    ctx.writeLine(line) catch {};
}

fn pushSystemNotice(raw_ctx: *anyopaque, text: []const u8) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.presenter) |presenter| return presenter.pushNotice(.{
        .topic = "system",
        .tone = .neutral,
        .body = text,
    });
    try ctx.writeStderr("[notice] ");
    try ctx.writeStderr(text);
    try ctx.writeStderr("\n");
}

fn pushContextNotice(raw_ctx: *anyopaque, text: []const u8) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (!try ctx.session.claimContextNotice(ctx.alloc, text)) return;
    if (ctx.presenter) |presenter| {
        const body = try types.renderContextNoticeBody(ctx.alloc, text);
        defer ctx.alloc.free(body);
        return presenter.pushNotice(.{
            .topic = "context",
            .tone = .warning,
            .body = body,
            .visibility = .full_only,
        });
    }
    try pushSystemNotice(raw_ctx, text);
}

fn beginRouteRecoveryRequest(raw_ctx: *anyopaque) void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.last_recovery_status = null;
    ctx.last_recovery_notice_kind = null;
}

fn pushRouteRecoveryStatus(raw_ctx: *anyopaque, status: types.RouteRecoveryStatus) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.last_recovery_status = status;
    if (status.kind == .retrying and ctx.last_recovery_notice_kind != status.kind) streamRetrying(ctx, status);
    const notice = switch (status.kind) {
        .waiting, .retrying, .need_user => notice: {
            const changed = ctx.last_recovery_notice_kind != status.kind;
            ctx.last_recovery_notice_kind = status.kind;
            break :notice changed and ctx.output_mode != .quiet;
        },

        .recovered, .failed => false,
        .terminal_provider_error => true,
        .unsafe_assistant_output,
        .unsafe_tool_start,
        .content_filter,
        => ctx.output_mode != .json and ctx.output_mode != .quiet,
    };
    if (!notice) return;
    var label_buf: [types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
    try pushSystemNotice(raw_ctx, status.label(&label_buf));
}

fn pushDiffBlock(raw_ctx: *anyopaque, payload: agent_runtime.DiffEntryPayload) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.presenter) |presenter| return presenter.pushDiffBlock(payload);
    defer diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
    try ctx.writeStderr(payload.preview);
}

fn pushCommandOutputComplete(raw_ctx: *anyopaque, _: ?types.ToolLifecycleId) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.output_mode.isTerminal() or !ctx.command_output_line_open) return;
    try ctx.writeStderr("\n");
    ctx.command_output_line_open = false;
}

fn pushHttpError(raw_ctx: *anyopaque, status: std.http.Status, detail: []const u8, credential_source: ?types.CredentialSource) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.failed = true;
    const auth_failure = auth_runtime.FailureSnapshot.fromHttp(status, credential_source);
    ctx.auth_failure = auth_failure;
    const message = if (auth_failure) |failure|
        try failure.renderText(ctx.alloc)
    else
        try gateway_error_format.formatHttpErrorMessage(ctx.alloc, status, detail);
    defer ctx.alloc.free(message);
    try ctx.writeStderr("fx ask: ");
    try ctx.writeStderr(message);
    try ctx.writeStderr("\n");
    if (ctx.output_mode.capturesJson()) {
        try ctx.assistant_output.appendSlice(ctx.alloc, message);
        try ctx.assistant_output.append(ctx.alloc, '\n');
    }
}

fn formatToolExecutionError(_: *anyopaque, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
    return tool_result_errors.formatToolExecutionErrorJson(arena, tool_name, err);
}

fn onCommandOutputChunk(raw_ctx: *anyopaque, _: ?types.ToolLifecycleId, _: command_output_content.Stream, chunk: []const u8) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.output_mode.isTerminal()) return;
    try ctx.writeStderr(chunk);
    if (chunk.len > 0) ctx.command_output_line_open = chunk[chunk.len - 1] != '\n';
}

fn onMcpProgress(raw_ctx: *anyopaque, lifecycle_id: types.ToolLifecycleId, text: []const u8) void {
    pushToolLifecycle(raw_ctx, .{ .progress = .{
        .id = lifecycle_id,
        .text = text,
    } }) catch |err| {
        debug_trace.logf("mcp", "failed to publish ask MCP progress err={s}", .{@errorName(err)});
    };
}

fn reportUnapprovedMcpServers(ctx: *AskContext, h: *mcp_host.Host) !void {
    for (h.notes) |note| {
        try ctx.writeStderr("note: ");
        try ctx.writeStderr(note);
        try ctx.writeStderr("\n");
    }
    var listed = false;
    for (h.runtime.servers()) |s| {
        if (s.held != .waiting_for_approval) continue;
        try ctx.writeStderr(if (listed) ", " else "fx ask: skipped unapproved project MCP servers: ");

        try ctx.writeStderr(s.name);
        listed = true;
    }
    if (listed) try ctx.writeStderr(". Approve with fx mcp approve <name> before retrying.\n");
}

fn respondToAskMcpInput(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    origin: tool_mcp_runtime.InputOrigin,
    required: tool_mcp_runtime.InputRequired,
) anyerror![]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (!ctx.mcp_elicitation_capabilities.any()) return error.McpInputRequired;
    return mcp_elicitation_interaction.respond(alloc, origin, required, .{
        .questioner = .{ .context = raw_ctx, .ask_fn = askTerminalMcpQuestion },
        .browser = .{ .context = raw_ctx, .open_fn = openAskMcpUrl },
        .capabilities = ctx.mcp_elicitation_capabilities,
    });
}

fn askTerminalMcpQuestion(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    entries: []const types.QuestionBatchEntry,
    deadline_ms: i64,
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
) anyerror!?[][]u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (!ctx.mcp_elicitation_capabilities.any()) return null;
    const answers = try alloc.alloc([]u8, entries.len);
    var answered: usize = 0;
    errdefer {
        for (answers[0..answered]) |answer| alloc.free(answer);
        alloc.free(answers);
    }
    for (entries) |entry| {
        try ctx.writeStderr("\n");
        try ctx.writeStderr(entry.question);
        try ctx.writeStderr("\n");
        for (entry.options, 0..) |option, index| {
            var number_buffer: [32]u8 = undefined;
            const prefix = try std.mem.print(&number_buffer, "  {d}. ", .{index + 1});
            try ctx.writeStderr(prefix);
            try ctx.writeStderr(option.label);
            if (option.description) |description| {
                try ctx.writeStderr(" — ");
                try ctx.writeStderr(description);
            }
            try ctx.writeStderr("\n");
        }
        if (entry.options.len > 0) {
            try ctx.writeStderr("Choose a number or enter a value: ");
        } else {
            try ctx.writeStderr("Enter a value: ");
        }
        ctx.dispatchAttentionRequired(.question);
        const line = try readAskTerminalLine(
            ctx,
            alloc,
            deadline_ms,
            lifecycle_cancel_flag,
        ) orelse {
            if (askAwakeMillis() >= deadline_ms) return error.McpInputTimedOut;
            return null;
        };
        defer alloc.free(line);
        answers[answered] = try mapTerminalAnswer(alloc, entry.options, line);
        answered += 1;
    }
    return answers;
}

fn mapTerminalAnswer(
    alloc: Allocator,
    options: []const types.QuestionOption,
    line: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    const ordinal = std.fmt.parseInt(usize, trimmed, 10) catch 0;
    if (ordinal > 0 and ordinal <= options.len) return alloc.dupe(u8, options[ordinal - 1].label);
    for (options) |option| {
        if (std.mem.eql(u8, trimmed, option.label)) return alloc.dupe(u8, option.label);
    }
    return alloc.dupe(u8, trimmed);
}

fn openAskMcpUrl(_: ?*anyopaque, alloc: Allocator, url: []const u8) anyerror!bool {
    return url_opener.native_opener.open(alloc, url);
}

const AskReadEvent = union(enum) {
    line: anyerror![]u8,
    watch: std.Io.Cancelable!select_watch.Outcome,
};

const AskReadCondition = struct {
    ctx: *AskContext,
    deadline_ms: i64,
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool),

    pub fn cancelled(condition: AskReadCondition) bool {
        if (condition.ctx.cancelFlag().load(.acquire)) return true;
        const flag = condition.lifecycle_cancel_flag orelse return false;
        return flag.load(.acquire);
    }

    pub fn expired(condition: AskReadCondition, _: std.Io) bool {
        return askAwakeMillis() >= condition.deadline_ms;
    }
};

const AskReadWatch = select_watch.Watch(AskReadCondition);

fn readAskTerminalLine(
    ctx: *AskContext,
    alloc: Allocator,
    deadline_ms: i64,
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
) !?[]u8 {
    const Cleanup = struct {
        fn drain(result_alloc: Allocator, select: *std.Io.Select(AskReadEvent), watch: *AskReadWatch) void {
            watch.stop(select.io);
            while (select.cancel()) |item| switch (item) {
                .line => |line_result| {
                    const line = line_result catch continue;
                    result_alloc.free(line);
                },
                .watch => {},
            };
        }
    };

    var watch: AskReadWatch = .{};
    var select_buffer: [2]AskReadEvent = undefined;
    var select: std.Io.Select(AskReadEvent) = .init(io_mod.getIo(), &select_buffer);
    try select.concurrent(.watch, AskReadWatch.run, .{ &watch, select.io, AskReadCondition{
        .ctx = ctx,
        .deadline_ms = deadline_ms,
        .lifecycle_cancel_flag = lifecycle_cancel_flag,
    } });
    select.concurrent(.line, readOwnedStdinLine, .{alloc}) catch |err| {
        watch.finish(&select);
        return err;
    };
    const event = select.await() catch |err| {
        Cleanup.drain(alloc, &select, &watch);
        return err;
    };
    return switch (event) {
        .line => |line_result| result: {
            watch.finish(&select);
            break :result line_result catch null;
        },

        .watch => result: {
            Cleanup.drain(alloc, &select, &watch);
            break :result null;
        },
    };
}

fn readOwnedStdinLine(alloc: Allocator) anyerror![]u8 {
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io_mod.getIo(), &read_buffer);
    const line = try reader.interface.takeDelimiter('\n') orelse return error.EndOfStream;
    return alloc.dupe(u8, line);
}

fn askAwakeMillis() i64 {
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const milliseconds = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
    return std.math.cast(i64, milliseconds) orelse if (milliseconds < 0)
        std.math.minInt(i64)
    else
        std.math.maxInt(i64);
}

fn resolveAskSubagentAuthority(
    raw: ?*anyopaque,
    alloc: Allocator,
    root_id: []const u8,
) subagent_authority.HostResolveError!subagent_authority.HostAuthority {
    const ctx: *AskContext = @ptrCast(@alignCast(raw.?));
    const active_id = if (ctx.v2) |v2| v2.id() else return error.HostAuthorityUnavailable;
    if (!std.mem.eql(u8, active_id, root_id)) {
        return error.HostAuthorityUnavailable;
    }
    const integrations = if (ctx.mcp_host) |h|
        h.catalog.snapshotToolNames(alloc, ctx.permission_rules)
    else
        alloc.alloc([]u8, 0);
    const owned_integrations = integrations catch return error.OutOfMemory;
    defer {
        for (owned_integrations) |name| alloc.free(name);
        alloc.free(owned_integrations);
    }
    var mcp_view = if (ctx.mcp_host) |h|
        try h.catalog.snapshotAccessView(alloc, root_id, root_id, ctx.permission_rules)
    else
        null;
    defer if (mcp_view) |*view| view.deinit(alloc);
    var permission_state = ctx.session.snapshotPermissionState(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.HostAuthorityUnavailable,
    };
    defer permission_state.deinit(alloc);
    return subagent_tool_host.captureHostAuthorityWithMcpView(
        alloc,
        .{
            .tool_set = ctx.deps.tool_set,
            .mode = .{
                .active = .{
                    .registry = ctx.cfg.mode_registry,
                    .id = ctx.mode_id,
                },
            },
        },
        owned_integrations,
        ctx.permission_rules,
        &.{},
        permission_state,
        if (mcp_view) |*view| view else null,
    );
}

const AskUsageProblem = union(enum) {
    none,
    flag: cli_flags.Failure,
    invalid_value: struct { flag: []const u8, value: []const u8 },
    conflict: []const u8,
    config: cli_config.OverrideProblem,
    settings: SettingsMessage,
    unreadable_file: struct { flag: []const u8, path: []const u8 },
};

const SettingsMessage = struct {
    bytes: [320]u8 = undefined,
    len: usize = 0,
};

const AskFlag = enum {
    config,
    settings,
    max_turns,
    dangerously_skip_permissions,
    system_prompt,
    system_prompt_file,
    append_system_prompt,
    append_system_prompt_file,
    permission_mode,
    ask,
    auto,
    full_access,
    yolo,
    y,
    yes,
    auto_approve,
    provider,
    model,
    effort,
    fast,
    no_fast,
    ultrafast,
    no_ultrafast,
    provider_order,
    provider_strict,
    no_provider_strict,
    image,
    system,
    json,
    output_format,
    quiet,
    prompt_permissions,
    permission_prompts,
    bare,
    allowed_tools,
    allowedTools,
    tools,
    disallowed_tools,
    disallowedTools,
    name,
    n,
    plan,
    timeout,
    no_save,
    no_session_persistence,
    no_color,
    @"resume",
    resume_id,
    @"continue",
    c,
};

const ask_flag_ids = cli_flags.idTable(AskFlag, &builtin_commands.ask_options);

fn parseOptionsWithStdin(alloc: Allocator, args: []const [:0]const u8, stdin: StdinSource) !AskOptions {
    var problem: AskUsageProblem = .none;
    return parseAskOptions(alloc, args, stdin, &problem);
}

fn parseAskOptions(alloc: Allocator, args: []const [:0]const u8, stdin: StdinSource, problem: *AskUsageProblem) !AskOptions {
    return parseInvocationOptions(alloc, .ask_command, args, stdin, problem);
}

pub const Invocation = enum {
    ask_command,
    prompt_flag,

    pub fn forCommandWord(word: []const u8) Invocation {
        return if (std.mem.eql(u8, word, "-p") or std.mem.eql(u8, word, "--prompt")) .prompt_flag else .ask_command;
    }
};

fn promptFlagConflict(id: AskFlag) ?[]const u8 {
    return switch (id) {
        .yolo, .y, .yes, .auto_approve => "Cannot combine --prompt with --yolo.",
        .full_access => "Cannot combine --prompt with --full-access.",
        .auto => "Cannot combine --prompt with --auto.",
        else => null,
    };
}

fn parseInvocationOptions(alloc: Allocator, invocation: Invocation, args: []const [:0]const u8, stdin: StdinSource, problem: *AskUsageProblem) !AskOptions {
    var opts: AskOptions = .{ .prompt = &.{} };
    errdefer opts.deinit(alloc);

    var prompt_parts: std.ArrayList([]const u8) = .empty;
    defer prompt_parts.deinit(alloc);
    var selected_yolo = false;
    var selected_auto = false;

    var parser = cli_flags.Parser.init(&builtin_commands.ask_options, args);
    while (parser.next() catch {
        problem.* = .{ .flag = parser.failure.? };
        return error.InvalidAskArgs;
    }) |item| {
        const match = switch (item) {
            .positional => |text| {
                try prompt_parts.append(alloc, text);
                continue;
            },
            .option => |option| option,
        };
        const value = match.value orelse "";
        const id = ask_flag_ids[match.index].?;
        if (invocation == .prompt_flag) if (promptFlagConflict(id)) |message| {
            problem.* = .{ .conflict = message };
            return error.InvalidAskArgs;
        };
        switch (id) {
            .yolo, .full_access, .y, .yes, .auto_approve => selected_yolo = true,
            .auto => selected_auto = true,
            else => {},
        }
        if (selected_yolo and selected_auto) {
            problem.* = .{ .conflict = "Cannot combine --yolo or --full-access with --auto." };
            return error.InvalidAskArgs;
        }
        if (agent_run_flags.fromId(id)) |flag| {
            opts.agent.apply(alloc, flag, value) catch |err| switch (err) {
                error.InvalidAgentRunValue => return invalidAskValue(problem, match, value),
                else => |other| return other,
            };
            continue;
        }
        switch (id) {
            .permission_mode, .ask, .auto, .full_access, .yolo, .y, .yes, .auto_approve, .provider, .model, .effort, .fast, .no_fast, .ultrafast, .no_ultrafast, .provider_order, .provider_strict, .no_provider_strict => unreachable,
            .image => try opts.image_paths.append(alloc, try alloc.dupe(u8, value)),
            .system, .system_prompt => {
                const owned_prompt = try alloc.dupe(u8, value);
                if (opts.system_prompt_override) |old| alloc.free(old);
                opts.system_prompt_override = owned_prompt;
            },
            .system_prompt_file => {
                const file_prompt = claude_flags.readPromptFile(alloc, value) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.UnreadablePromptFile => return unreadableAskFile(problem, match, value),
                };
                if (opts.system_prompt_override) |old| alloc.free(old);
                opts.system_prompt_override = file_prompt;
            },
            .append_system_prompt => opts.system_prompt_append = try claude_flags.joinAppended(alloc, opts.system_prompt_append, value),
            .append_system_prompt_file => {
                const file_prompt = claude_flags.readPromptFile(alloc, value) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.UnreadablePromptFile => return unreadableAskFile(problem, match, value),
                };
                defer alloc.free(file_prompt);
                opts.system_prompt_append = try claude_flags.joinAppended(alloc, opts.system_prompt_append, file_prompt);
            },
            .dangerously_skip_permissions => opts.agent.permission = types.PermissionMode.parse("bypassPermissions").?,
            .max_turns => {
                var write_problem: cli_config.WriteProblem = .none;
                const planned = cli_config.change(.{ .action = .set, .key = "max_agent_steps", .value = value }, &write_problem) catch
                    return invalidAskValue(problem, match, value);
                try opts.settings_overrides.append(alloc, .{ .key = "max_agent_steps", .value = planned.value.? });
            },
            .settings => {
                if (opts.settings_arena == null) opts.settings_arena = std.heap.ArenaAllocator.init(alloc);
                const settings_arena = if (opts.settings_arena) |*held| held.allocator() else unreachable;
                var settings_problem: claude_flags.SettingsProblem = .none;
                const settings_text = claude_flags.settingsText(settings_arena, value, &settings_problem) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidSettingsFlag => return invalidAskSettings(alloc, problem, settings_problem),
                };
                const overrides = claude_flags.settingsOverrides(settings_arena, settings_text, &settings_problem) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidSettingsFlag => return invalidAskSettings(alloc, problem, settings_problem),
                };
                try opts.settings_overrides.appendSlice(alloc, overrides);
            },
            .json => opts.json_output = true,
            .output_format => if (std.mem.eql(u8, value, "json")) {
                opts.json_output = true;
            } else {
                opts.output_format = print_stream.OutputFormat.parse(value) orelse
                    return invalidAskValue(problem, match, value);
            },
            .quiet => opts.quiet = true,
            .prompt_permissions => opts.prompt_permissions = true,
            .permission_prompts => {
                if (std.mem.eql(u8, value, "none")) {
                    opts.agent.permission = .dontAsk;
                } else if (!std.mem.eql(u8, value, "host")) {
                    return invalidAskValue(problem, match, value);
                }
            },
            .name, .n => {
                if (value.len == 0) return invalidAskValue(problem, match, value);
                if (opts.session_name) |old| alloc.free(old);
                opts.session_name = try alloc.dupe(u8, value);
            },
            .bare => opts.bare = true,
            .allowed_tools, .allowedTools => {
                var checked = config_runtime.allowRulesFromToolLists(alloc, &.{value}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return invalidAskValue(problem, match, value),
                };
                checked.deinit(alloc);
                try opts.allowed_tools.append(alloc, try alloc.dupe(u8, value));
            },
            .tools => {
                if (opts.tools) |old| alloc.free(old);
                opts.tools = try alloc.dupe(u8, value);
            },
            .disallowed_tools, .disallowedTools => try opts.disallowed_tools.append(alloc, try alloc.dupe(u8, value)),
            .plan => {
                problem.* = .{ .conflict = "Cannot combine --prompt with --plan." };
                return error.InvalidAskArgs;
            },
            .timeout => opts.timeout_ms = parseTimeoutMs(value) orelse
                return invalidAskValue(problem, match, value),
            .no_save, .no_session_persistence => opts.no_save = true,
            .@"continue", .c => opts.resume_target = .last,
            .no_color => opts.no_color = true,
            .@"resume" => {
                const target = std.mem.trim(u8, value, " \t\r\n");
                if (target.len == 0) return invalidAskValue(problem, match, value);
                opts.resume_target = if (std.mem.eql(u8, target, "last"))
                    .last
                else
                    .{ .id = session_store.sessionIdFromTranscriptPath(target) orelse target };
            },

            .resume_id => unreachable,
            .config => {
                var override_problem: cli_config.OverrideProblem = .none;
                const override = cli_config.parseOverride(value, &override_problem) catch {
                    problem.* = .{ .config = override_problem };
                    return error.InvalidAskArgs;
                };
                try opts.settings_overrides.append(alloc, override);
            },
        }
    }

    if (opts.output_format != null and (opts.json_output or opts.quiet)) {
        problem.* = .{ .conflict = "Cannot combine --output-format with --json or --quiet." };
        return error.InvalidAskArgs;
    }
    if (prompt_parts.items.len > 0) {
        opts.prompt = try joinPromptSlices(alloc, prompt_parts.items);
    } else {
        opts.prompt = try readPromptFromStdinSource(alloc, stdin);
    }
    if (!text_utils.isModelSafeText(opts.prompt)) return error.InvalidPromptText;
    if (opts.no_save and opts.resume_target != null) return error.NoSaveResumeConflict;
    if (invocation == .prompt_flag and opts.agent.permission == null) opts.agent.permission = .auto;

    return opts;
}

fn writeAskUsageProblem(alloc: Allocator, deps: RunDeps, problem: AskUsageProblem, prefix: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    switch (problem) {
        .none => return,
        .flag => |failure| {
            try out.writer.writeAll(prefix);
            try failure.write(&out.writer);
            try flag_placement.writeLaunchFlagHint(&out.writer, "ask", failure);
        },
        .invalid_value => |bad| try out.writer.print("{s}invalid value for {s}: {f}", .{ prefix, bad.flag, text_utils.terminalSafe(bad.value) }),
        .conflict => |message| try out.writer.print("{s}{s}", .{ prefix, message }),
        .settings => |message| try out.writer.print("{s}{s}", .{ prefix, message.bytes[0..message.len] }),
        .unreadable_file => |bad| try out.writer.print("{s}{s} could not read {f}", .{ prefix, bad.flag, text_utils.terminalSafe(bad.path) }),
        .config => |bad| {
            const message = try cli_config.formatOverrideProblem(alloc, bad);
            defer alloc.free(message);
            try out.writer.print("{s}{s}", .{ prefix, message });
        },
    }
    try out.writer.writeByte('\n');
    try deps.write_stderr(deps.stderr_ctx, out.written());
}

fn unreadableAskFile(problem: *AskUsageProblem, match: cli_flags.Match, path: []const u8) error{InvalidAskArgs} {
    problem.* = .{ .unreadable_file = .{
        .flag = cli_flags.flagName(builtin_commands.ask_options[match.index]),
        .path = path,
    } };
    return error.InvalidAskArgs;
}

fn invalidAskSettings(alloc: Allocator, problem: *AskUsageProblem, why: claude_flags.SettingsProblem) error{ InvalidAskArgs, OutOfMemory } {
    const text = claude_flags.formatSettingsProblem(alloc, why) catch return error.OutOfMemory;
    defer alloc.free(text);
    var message: SettingsMessage = .{};
    message.len = @min(text.len, message.bytes.len);
    @memcpy(message.bytes[0..message.len], text[0..message.len]);
    problem.* = .{ .settings = message };
    return error.InvalidAskArgs;
}

fn invalidAskValue(problem: *AskUsageProblem, match: cli_flags.Match, value: []const u8) error{InvalidAskArgs} {
    problem.* = .{ .invalid_value = .{
        .flag = cli_flags.flagName(builtin_commands.ask_options[match.index]),
        .value = value,
    } };
    return error.InvalidAskArgs;
}

const default_plan_mode_skipped_notice = "default_plan_mode is not applied in print mode, because Plan mode waits for your review.\n";

fn emitHeadlessYoloWarning(alloc: Allocator, options: RunOptions) !void {
    if (options.color_enabled and options.deps.stderr_is_tty(options.deps.stderr_ctx)) {
        try options.deps.write_stderr(
            options.deps.stderr_ctx,
            "\x1b[38;5;252m" ++ permissions.yolo_warning_text ++ "\x1b[0m\n",
        );
    } else {
        try options.deps.write_stderr(options.deps.stderr_ctx, permissions.yolo_warning_text ++ "\n");
    }

    var attempt = options.deps.persist_yolo_acknowledgment(alloc);
    defer attempt.deinit(alloc);
    switch (attempt) {
        .outcome => {},
        .failure => |failure| {
            var message: std.Io.Writer.Allocating = .init(alloc);
            defer message.deinit();
            try message.writer.print(
                "fx ask: failed to save full access acknowledgment: {s}\n",
                .{@errorName(failure.err)},
            );
            try options.deps.write_stderr(options.deps.stderr_ctx, message.written());
        },
    }
}

fn persistYoloAcknowledgmentDefault(alloc: Allocator) config_runtime.CommitAttempt {
    return config_runtime.attemptUserPreferences(
        alloc,
        .{ .yolo_acknowledged = true },
    );
}

fn hasJsonFlag(args: []const [:0]const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) return false;
        if (std.mem.eql(u8, arg, "--json")) return true;
    }
    return false;
}

fn parseTimeoutMs(raw: []const u8) ?usize {
    const seconds = std.fmt.parseInt(usize, raw, 10) catch return null;
    return std.math.mul(usize, seconds, std.time.ms_per_s) catch null;
}

fn joinPromptSlices(alloc: Allocator, args: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (args, 0..) |arg, idx| {
        if (idx > 0) try out.writer.writeByte(' ');
        try out.writer.writeAll(arg);
    }
    return try out.toOwnedSlice();
}

fn readPromptFromStdinSource(alloc: Allocator, stdin: StdinSource) ![]u8 {
    return readPromptFromStdinSourceWithLimit(alloc, stdin, stdin_prompt_resource_byte_limit);
}

fn readPromptFromStdinSourceWithLimit(
    alloc: Allocator,
    stdin: StdinSource,
    resource_byte_limit: usize,
) ![]u8 {
    const input = switch (stdin) {
        .real => blk: {
            if (try std.Io.File.stdin().isTty(io_mod.getIo())) return error.MissingPrompt;
            break :blk try readPromptFromStdin(alloc, resource_byte_limit);
        },
        .tty => return error.MissingPrompt,
        .bytes => |bytes| blk: {
            if (bytes.len > resource_byte_limit) return error.PromptResourceLimitExceeded;
            break :blk try alloc.dupe(u8, bytes);
        },
        .read_error => return error.PromptInputReadFailed,
    };
    errdefer alloc.free(input);

    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return error.MissingPrompt;
    if (trimmed.len == input.len) return input;

    const owned = try alloc.dupe(u8, trimmed);
    alloc.free(input);
    return owned;
}

fn readPromptFromStdin(alloc: Allocator, resource_byte_limit: usize) ![]u8 {
    const zio = io_mod.getIo();
    var read_buf: [8192]u8 = undefined;
    var r = std.Io.File.stdin().reader(zio, &read_buf);
    return readPromptFromReader(alloc, &r.interface, resource_byte_limit);
}

fn readPromptFromReader(
    alloc: Allocator,
    reader: *std.Io.Reader,
    resource_byte_limit: usize,
) ![]u8 {
    const detection_limit = std.math.add(usize, resource_byte_limit, 1) catch
        return error.PromptResourceLimitExceeded;
    const input = reader.allocRemaining(alloc, .limited(detection_limit)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.PromptResourceLimitExceeded,
        else => return error.PromptInputReadFailed,
    };
    if (input.len > resource_byte_limit) {
        alloc.free(input);
        return error.PromptResourceLimitExceeded;
    }
    return input;
}

fn renderFinalJsonResult(alloc: Allocator, result: PromptRunResult) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.writeAll("{\"output\":");
    try std.json.Stringify.value(result.assistant_output, .{}, &out.writer);
    try out.writer.writeAll(",\"final_output\":");
    try std.json.Stringify.value(result.final_output, .{}, &out.writer);
    try out.writer.print(",\"exit_code\":{d}", .{result.exit_code});
    if (result.blocked_by_limit) try out.writer.writeAll(",\"blocked\":\"limit\"");
    try out.writer.writeAll(",\"model\":");
    try std.json.Stringify.value(result.model, .{}, &out.writer);
    try out.writer.writeAll(",\"resolved_provider\":");
    if (result.resolved_provider.len > 0) {
        try std.json.Stringify.value(result.resolved_provider, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"session_id\":");
    try std.json.Stringify.value(result.session_id, .{}, &out.writer);
    try out.writer.print(",\"steps\":{d}", .{result.step_count});
    try out.writer.writeAll(",\"tool_calls\":[");
    for (result.tool_calls, 0..) |tc, i| {
        if (i > 0) try out.writer.writeAll(",");
        try out.writer.writeAll("{\"name\":");
        try std.json.Stringify.value(tc.name, .{}, &out.writer);
        try out.writer.writeAll(",\"status\":");
        try std.json.Stringify.value(tc.status, .{}, &out.writer);
        if (tc.error_category) |category| {
            try out.writer.writeAll(",\"error\":{\"category\":");
            try std.json.Stringify.value(@tagName(category), .{}, &out.writer);
            try out.writer.writeAll(",\"code\":");
            try std.json.Stringify.value(
                tc.error_code orelse "tool_failed",
                .{},
                &out.writer,
            );
            try out.writer.writeByte('}');
        }
        if (tc.command_result_json) |json| {
            try out.writer.writeAll(",\"command_result\":");
            try out.writer.writeAll(json);
        }
        if (tc.ask_question_text) |text| {
            try out.writer.writeAll(",\"question\":");
            try std.json.Stringify.value(text, .{}, &out.writer);
        }
        if (tc.web_search_completion) |completion| {
            try out.writer.print(",\"WebSearch\":{{\"searches\":{d},\"duration_ms\":{d}}}", .{ completion.searches, completion.duration_ms });
        }
        if (tc.web_fetch_completion) |completion| {
            try out.writer.writeAll(",\"FetchURL\":{\"url\":");
            try std.json.Stringify.value(completion.url(), .{}, &out.writer);
            try out.writer.print(",\"bytes\":{d},\"status\":{d},\"duration_ms\":{d},\"cache_hit\":{s},\"artifact\":\"{s}\"}}", .{
                completion.bytes,
                completion.status,
                completion.duration_ms,
                if (completion.cache_hit) "true" else "false",
                @tagName(completion.artifact_state),
            });
        }
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("],\"usage\":{\"input_tokens\":");
    try std.json.Stringify.value(result.usage.input_tokens, .{}, &out.writer);
    try out.writer.writeAll(",\"output_tokens\":");
    try std.json.Stringify.value(result.usage.output_tokens, .{}, &out.writer);

    if (result.usage.cache_read_tokens) |tokens| try out.writer.print(",\"cache_read_tokens\":{d}", .{tokens});
    if (result.usage.cache_write_tokens) |tokens| try out.writer.print(",\"cache_write_tokens\":{d}", .{tokens});
    try out.writer.writeAll("}");
    if (result.error_code) |error_code| {
        try out.writer.writeAll(",\"error\":");
        try std.json.Stringify.value(error_code, .{}, &out.writer);
    }
    if (result.auth_failure) |failure| {
        try out.writer.writeAll(",\"auth_failure\":");
        try failure.writeJson(&out.writer);
    }
    if (result.recovery) |recovery| {
        var label_buf: [types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
        try out.writer.writeAll(",\"recovery\":");
        try recovery.report(&label_buf).writeJson(&out.writer);
    }
    try out.writer.writeAll("}\n");
    return try out.toOwnedSlice();
}

fn renderErrorJsonResult(alloc: Allocator, err_name: []const u8, exit_code: u8) ![]u8 {
    return renderFinalJsonResult(alloc, .{
        .exit_code = exit_code,
        .assistant_output = &.{},
        .error_code = err_name,
    });
}

fn toCoreReasoningEffort(effort: types.ReasoningEffort) types.ReasoningEffort {
    return effort;
}

fn toCorePermissionMode(mode: anytype) PermissionMode {
    return switch (mode) {
        .ask => .ask,
        .auto => .auto,
        .yolo => .yolo,
        .dontAsk => .dontAsk,
    };
}

fn takeCorePermissionRules(_: Allocator, startup: *app_lifecycle.StartupState) !types.PermissionRuleSet {
    return startup.takePermissionRules();
}

fn applyAskThemeChoice(settings_theme: ?[]const u8) void {
    var configured: ?[]const u8 = settings_theme;
    if (io_mod.getenv("FX_THEME")) |value| {
        if (value.len > 0) configured = value;
    }
    const choice = if (configured) |value| shared_theme.classifyValue(value) else null;
    if (choice) |selected| switch (selected) {
        .pin_light, .pin_dark => {
            shared_theme.setSource(null, true);
            ui_render.initTheme(selected == .pin_light, null);
        },
        .custom => |name| shared_theme.setSource(name, false),
    };
}

fn loadStartupStateDefault(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
    provider_override: ?model_provider.ProviderId,
    model_override: ?[]const u8,
    settings_overrides: []const config_runtime.SettingOverride,
) !app_lifecycle.StartupState {
    return app_lifecycle.loadStartupStateForRunWithOverrides(
        alloc,
        transport,
        secret_store,
        default_model,
        default_agent_step_limit,
        .local,
        provider_override,
        model_override,
        settings_overrides,
    );
}

fn initializeSessionStoresDefault(ctx: *AskContext) !void {
    try ctx.initializeSessionStores();
}

fn testInitializeSessionStoresOneOffDenied(_: *AskContext) !void {
    return error.OneOffSessionNotResumable;
}

fn processQueuedPromptDefault(agent: *agent_runtime.Agent, deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, lifecycle: agent_runtime.LifecycleContext, config: agent_runtime.Config, job: worker_runtime.QueuedPrompt) !void {
    return agent_runtime.processAgentPrompt(agent, deps, semantic_presentation, lifecycle, config, job);
}

fn promptRealPermissionApproval(
    _: ?*anyopaque,
    stderr_ctx: ?*anyopaque,
    write_stderr: WriteFn,
    label: []const u8,
    attention_ctx: ?*anyopaque,
    notify_attention: NotifyAttentionFn,
) !PermissionApprovalPromptResult {
    const zio = io_mod.getIo();
    const stdin_tty = std.Io.File.stdin().isTty(zio) catch false;
    if (!stdin_tty) return .unavailable;

    try write_stderr(stderr_ctx, "fx wants to run:\n  ");
    try write_stderr(stderr_ctx, label);
    try write_stderr(stderr_ctx, "\n\nApprove? [y/N] ");
    notify_attention(attention_ctx);

    var read_buf: [256]u8 = undefined;
    var reader = std.Io.File.stdin().reader(zio, &read_buf);
    const line = reader.interface.takeDelimiter('\n') catch return .deny;
    const answer = std.mem.trim(u8, line orelse "", " \t\r\n");
    if (answer.len == 1 and (answer[0] == 'y' or answer[0] == 'Y')) return .approve;
    return .deny;
}

fn realStderrIsTty(_: ?*anyopaque) bool {
    return std.Io.File.stderr().isTty(io_mod.getIo()) catch false;
}

fn realStdinIsTty(_: ?*anyopaque) bool {
    return std.Io.File.stdin().isTty(io_mod.getIo()) catch false;
}

fn realStdoutIsTty(_: ?*anyopaque) bool {
    return std.Io.File.stdout().isTty(io_mod.getIo()) catch false;
}

fn writeRealStdout(_: ?*anyopaque, text: []const u8) !void {
    std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text) catch |err| {
        debug_trace.logf("core", "ask output write failed err={s}", .{@errorName(err)});
        if (err == error.BrokenPipe) return error.OutputReaderGone;
        return error.OutputWriteFailed;
    };
}

fn writeRealStderr(_: ?*anyopaque, text: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), text);
}

const TestCapture = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestCapture, alloc: Allocator) void {
        self.bytes.deinit(alloc);
    }

    fn write(raw_ctx: ?*anyopaque, text: []const u8) !void {
        const self: *TestCapture = @ptrCast(@alignCast(raw_ctx.?));
        try self.bytes.appendSlice(std.testing.allocator, text);
    }
};

const TestPermissionPrompt = struct {
    result: PermissionApprovalPromptResult = .unavailable,
    calls: usize = 0,
    label: ?[]const u8 = null,

    fn prompt(
        raw_ctx: ?*anyopaque,
        stderr_ctx: ?*anyopaque,
        write_stderr: WriteFn,
        label: []const u8,
        attention_ctx: ?*anyopaque,
        notify_attention: NotifyAttentionFn,
    ) !PermissionApprovalPromptResult {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        self.calls += 1;
        self.label = label;
        if (self.result != .unavailable) {
            try write_stderr(stderr_ctx, "fx wants to run:\n  ");
            try write_stderr(stderr_ctx, label);
            try write_stderr(stderr_ctx, "\n\nApprove? [y/N] ");
            notify_attention(attention_ctx);
        }
        return self.result;
    }
};

const TestTty = struct {
    fn yes(_: ?*anyopaque) bool {
        return true;
    }

    fn no(_: ?*anyopaque) bool {
        return false;
    }
};

const TestYoloPersistence = struct {
    var calls: usize = 0;
    var warning_capture: ?*const TestCapture = null;
    var observed_warning_before_persist: bool = false;

    fn reset() void {
        calls = 0;
        warning_capture = null;
        observed_warning_before_persist = false;
    }

    fn persist(_: Allocator) config_runtime.CommitAttempt {
        calls += 1;
        if (warning_capture) |capture| {
            observed_warning_before_persist =
                std.mem.find(u8, capture.bytes.items, permissions.yolo_warning_text) != null;
        }
        return .{ .outcome = .unchanged };
    }
};

const TestFailingStderr = struct {
    fn write(_: ?*anyopaque, _: []const u8) !void {
        return error.TestStderrWriteFailed;
    }
};

const AskAttentionCapture = struct {
    calls: usize = 0,
    turn_id: u64 = 0,
    kind: ?hooks.AttentionKind = null,

    fn run(raw: *anyopaque, input: hooks.AttentionRequiredInput) hooks.HandlerError!void {
        const self: *AskAttentionCapture = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.turn_id = input.invocation.turn_id orelse 0;
        self.kind = input.kind;
    }
};

const test_modes = [_]mode_registry.ModeSpec{
    .{
        .id = "inspect",
        .name = "Inspect",
        .permission_mode = .ask,
    },
};

const test_mode_registry = mode_registry.Registry{
    .default_mode_id = "inspect",
    .modes = test_modes[0..],
};

fn testModelPromptOverlay(model: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, model, "model")) "test model overlay" else null;
}

fn testConfig() Config {
    return .{
        .command_usage = "ask [--auto|--full-access] [--image PATH] [--json] [--quiet] [--prompt-permissions] [--no-save] [--no-color] [--resume <last|<id>>] [--] <prompt>",
        .default_model = "model",
        .default_agent_step_limit = 4,
        .gateway_retry_count = 1,
        .gateway_chat_url = "https://example.invalid/chat",
        .gateway_models_path = "/models",
        .gateway_provider = test_builtin_gateway.provider,
        .provider_set = provider_set.gateway_only(test_builtin_gateway.provider_bundle),
        .secret_store = host.unavailable_secret_store,
        .prompt_policy = .{
            .system_prompt = "system",
            .model_prompt_overlay_fn = testModelPromptOverlay,
        },
        .skill_root_policy = .{ .managed_root_source = .global_fx },
        .ignored_list_entries = &.{},
        .max_list_entries = 10,
        .max_read_file_bytes = 1024,
        .max_read_file_lines = 100,
        .max_read_file_line_len = 200,
        .max_command_output_bytes = 4096,
        .max_tool_result_bytes = 4096,
        .max_history_turns = 2,
        .mode_registry = test_mode_registry,
    };
}

fn testMissingKeyStartup(alloc: Allocator, _: oauth_transport.Provider, _: host.SecretStore, default_model: []const u8, default_agent_step_limit: usize, _: ?model_provider.ProviderId, _: ?[]const u8, _: []const config_runtime.SettingOverride) !app_lifecycle.StartupState {
    var state = app_lifecycle.StartupState{ .agent_step_limit = default_agent_step_limit };
    errdefer state.deinit(alloc);
    state.workspace_root = try alloc.dupe(u8, "/tmp/fx-test");
    state.selected_model = try alloc.dupe(u8, default_model);
    state.context_enabled = false;
    return state;
}

fn testPresentKeyStartup(alloc: Allocator, _: oauth_transport.Provider, _: host.SecretStore, default_model: []const u8, default_agent_step_limit: usize, _: ?model_provider.ProviderId, _: ?[]const u8, _: []const config_runtime.SettingOverride) !app_lifecycle.StartupState {
    var state = app_lifecycle.StartupState{ .agent_step_limit = default_agent_step_limit };
    errdefer state.deinit(alloc);
    state.workspace_root = try alloc.dupe(u8, "/tmp/fx-test");
    state.credential = .{
        .token = try alloc.dupe(u8, "key"),
        .source = .ai_gateway_api_key,
    };
    state.selected_model = try alloc.dupe(u8, default_model);
    state.context_enabled = true;
    return state;
}

fn testMissingKeyAcknowledgedStartup(alloc: Allocator, transport: oauth_transport.Provider, secret_store: host.SecretStore, default_model: []const u8, default_agent_step_limit: usize, _: ?model_provider.ProviderId, _: ?[]const u8, _: []const config_runtime.SettingOverride) !app_lifecycle.StartupState {
    var state = try testMissingKeyStartup(alloc, transport, secret_store, default_model, default_agent_step_limit, null, null, &.{});
    state.yolo_acknowledged = true;
    return state;
}

fn testMissingKeyDiagnosticStartup(alloc: Allocator, transport: oauth_transport.Provider, secret_store: host.SecretStore, default_model: []const u8, default_agent_step_limit: usize, _: ?model_provider.ProviderId, _: ?[]const u8, _: []const config_runtime.SettingOverride) !app_lifecycle.StartupState {
    var state = try testMissingKeyStartup(alloc, transport, secret_store, default_model, default_agent_step_limit, null, null, &.{});
    errdefer state.deinit(alloc);
    state.config_diagnostics = try alloc.alloc(config_runtime.ConfigDiagnostic, 1);
    state.config_diagnostics[0] = .{
        .layer = .user,
        .cause = .malformed_settings,
    };
    return state;
}

fn testPresentKeySavedStartup(alloc: Allocator, transport: oauth_transport.Provider, secret_store: host.SecretStore, default_model: []const u8, default_agent_step_limit: usize, _: ?model_provider.ProviderId, _: ?[]const u8, _: []const config_runtime.SettingOverride) !app_lifecycle.StartupState {
    var state = try testPresentKeyStartup(alloc, transport, secret_store, default_model, default_agent_step_limit, null, null, &.{});
    errdefer state.deinit(alloc);
    state.configured_model = try alloc.dupe(u8, default_model);
    return state;
}

fn testPushAssistantText(deps: *const agent_runtime.AgentRuntimeDeps, text: []const u8) !void {
    try deps.push_text(deps.ctx, .{ .assistant_source = text });
    try deps.push_text(deps.ctx, .{ .assistant_rendered = text });
}

fn testProcessQueuedPrompt(_: *agent_runtime.Agent, deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, lifecycle: agent_runtime.LifecycleContext, _: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try std.testing.expectEqual(hooks.ScopeKind.ask, lifecycle.scope.kind);
    try std.testing.expectEqualStrings("/tmp/fx-test", lifecycle.scope.workspace_root);
    try testPushAssistantText(deps, "assistant text");
}

fn testProcessQueuedPromptRecoveryLifecycle(_: *agent_runtime.Agent, deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, lifecycle: agent_runtime.LifecycleContext, _: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try std.testing.expectEqual(hooks.ScopeKind.ask, lifecycle.scope.kind);

    try deps.push_route_recovery_status(deps.ctx, .{ .kind = .waiting, .text = testRecoveryText("Offline · next try in 2s · 0s"), .attempt = 1 });
    try deps.push_route_recovery_status(deps.ctx, .{ .kind = .waiting, .text = testRecoveryText("Offline · next try in 1s · 1s"), .attempt = 1 });
    try deps.push_route_recovery_status(deps.ctx, .{ .kind = .retrying, .text = testRecoveryText("Offline · retrying · attempt 2 · 2s"), .attempt = 2 });
    try deps.push_event(deps.ctx, .clear_route_recovery_status);
    try deps.push_route_recovery_status(deps.ctx, .{ .kind = .recovered, .attempt = 2 });
    try testPushAssistantText(deps, "assistant text");
}

const testRecoveryText = types.testRecoveryText;

fn testProcessQueuedPromptRecoveredThenFailed(_: *agent_runtime.Agent, deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, _: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    const begin = deps.begin_route_recovery_request.?;

    begin(deps.ctx);
    try deps.push_route_recovery_status(deps.ctx, .{ .kind = .waiting, .text = testRecoveryText("Gateway error · next try in 1s · attempt 1 · 0s"), .attempt = 1 });
    try deps.push_event(deps.ctx, .clear_route_recovery_status);
    try deps.push_route_recovery_status(deps.ctx, .{ .kind = .recovered, .attempt = 2 });

    begin(deps.ctx);
    try deps.push_http_error(deps.ctx, .bad_request, "bad request body", null);
    return error.ModelError;
}

fn testProcessQueuedPromptRetryAdmissionFailure(_: *agent_runtime.Agent, deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, _: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try deps.push_route_recovery_status(deps.ctx, .{
        .kind = .waiting,
        .text = testRecoveryText("Gateway error · next try in 4s · attempt 1 · 0s"),
        .attempt = 1,
    });
    try deps.push_route_recovery_status(deps.ctx, .{
        .kind = .terminal_provider_error,
        .attempt = 1,
        .diagnostic = types.ModelFailureDiagnostic.init("TestProviderSerializationFailed"),
    });
    return error.TestProviderSerializationFailed;
}

fn testProcessQueuedPromptPartialThenReadFailed(_: *agent_runtime.Agent, deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, _: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try testPushAssistantText(deps, "partial ");
    try testPushAssistantText(deps, "résumé");
    return error.ReadFailed;
}

fn testProcessQueuedPromptRepeatsSkillDiagnostic(agent: *agent_runtime.Agent, deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, lifecycle: agent_runtime.LifecycleContext, cfg: agent_runtime.Config, job: worker_runtime.QueuedPrompt) !void {
    try std.testing.expectEqual(@as(usize, 1), cfg.skill_catalog.skills.len);
    try std.testing.expectEqualStrings("visible", cfg.skill_catalog.skills[0].name);
    try std.testing.expectEqual(@as(usize, 1), cfg.skill_catalog.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.context_limits.skill_catalog_bytes.effectiveBytes());
    const diagnostics = [_]skill_runtime.SkillDiagnostic{.{
        .path = "/tmp/bad-skill/SKILL.md",
        .source = .workspace_shared,
        .scope = .candidate,
        .cause = .{ .invalid_metadata = .missing_name },
    }};
    var notice: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer notice.deinit();
    try skill_runtime.writeDiagnosticSummary(std.testing.allocator, &notice.writer, &diagnostics);
    try deps.push_context_notice.?(deps.ctx, notice.written());
    try deps.push_context_notice.?(deps.ctx, notice.written());
    try testProcessQueuedPrompt(agent, deps, semantic_presentation, lifecycle, cfg, job);
}

fn testProcessQueuedPromptChecksTimeout(_: *agent_runtime.Agent, deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, _: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    const ctx: *AskContext = @ptrCast(@alignCast(deps.ctx));
    try std.testing.expectEqual(@as(?usize, std.time.ms_per_s), ctx.command_timeout_ms);
    const tool_ctx = ctx.toolContext();
    try std.testing.expectEqual(@as(?usize, std.time.ms_per_s), tool_ctx.command_timeout_ms);
    try std.testing.expect(!tool_ctx.web_search_runtime_ready);
    try std.testing.expect(tool_ctx.web_search_backend != null);
    try std.testing.expect(tool_ctx.web_fetch_runtime.? == &ctx.web_fetch_runtime);
    try std.testing.expect(tool_ctx.web_fetch_progress_ctx != null);
    try std.testing.expect(tool_ctx.on_web_fetch_progress != null);
    try std.testing.expectEqualStrings(ctx.model, ctx.web_search_runtime.worker_model);
    try std.testing.expectEqual(ctx.cfg.gateway_retry_count, ctx.web_search_runtime.gateway_retry_count);
    try std.testing.expectEqualStrings(ctx.cfg.gateway_chat_url, ctx.web_search_runtime.gateway_chat_url);
    try std.testing.expect(ctx.web_search_runtime.provider.?.execute_fn == ctx.cfg.provider_set.gateway.fx_search.?.execute_fn);
    try std.testing.expectEqualStrings("/models", tool_ctx.gateway_models_path);
    try testPushAssistantText(deps, "assistant text");
}

fn testProcessQueuedPromptChecksExecOnlyTerminal(_: *agent_runtime.Agent, deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, cfg: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try std.testing.expect(cfg.session_child_capability == null);
    try std.testing.expect(cfg.ephemeral_command_replay != null);
    const ctx: *AskContext = @ptrCast(@alignCast(deps.ctx));
    try std.testing.expect(ctx.toolContext().ephemeral_command_replay != null);
    try std.testing.expectEqualStrings("inspect", ctx.mode_id);
    try std.testing.expectEqual(@as(usize, 1), cfg.advertised_tool_names.len);
    try std.testing.expect(tool_projection_mod.containsName(cfg.advertised_tool_names, "run_code"));
    try std.testing.expectEqualStrings(builtin_tools.web_search.description, cfg.custom_tool_guidance);
    try std.testing.expectEqualStrings("test model overlay", cfg.model_prompt_overlay.?);
    const runtime_shell = deps.tool_registry.lookup("Bash") orelse
        return error.TestExpectedEqual;
    try std.testing.expect(std.mem.find(u8, runtime_shell.description, "run_in_background") != null);
    try std.testing.expectEqualStrings("command", runtime_shell.model_schema.input_schema.properties[0].name);
    for (runtime_shell.model_schema.input_schema.properties) |property| {
        try std.testing.expect(!std.mem.eql(u8, property.name, "tty"));
    }
    try testPushAssistantText(deps, "assistant text");
}

fn testProcessQueuedPromptChecksFullTerminal(_: *agent_runtime.Agent, deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, cfg: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try std.testing.expect(cfg.session_child_capability != null);
    try std.testing.expectEqual(@as(usize, 1), cfg.advertised_tool_names.len);
    try std.testing.expect(tool_projection_mod.containsName(cfg.advertised_tool_names, "run_code"));
    const runtime_shell = deps.tool_registry.lookup("Bash") orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.find(u8, runtime_shell.description, "run_in_background") != null);
    try std.testing.expect(std.mem.find(u8, runtime_shell.description, "tty=true") == null);
    try testPushAssistantText(deps, "assistant text");
}

fn testProcessQueuedPromptChecksInjectedToolSet(_: *agent_runtime.Agent, deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, cfg: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try std.testing.expect(tool_projection_mod.containsName(cfg.advertised_tool_names, "read_file"));
    try std.testing.expect(!tool_projection_mod.containsName(cfg.advertised_tool_names, "run_command"));
    try std.testing.expectEqualStrings("", cfg.custom_tool_guidance);

    const ctx: *AskContext = @ptrCast(@alignCast(deps.ctx));
    try std.testing.expect(ctx.toolRegistry().lookup("read_file") != null);
    try std.testing.expect(ctx.toolRegistry().lookup("run_command") == null);
    try testPushAssistantText(deps, "assistant text");
}

fn testProcessQueuedPromptHttp413(_: *agent_runtime.Agent, deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, _: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try deps.push_http_error(
        deps.ctx,
        .payload_too_large,
        "provider payload rejected\n\nprompt_too_long=true\nProvider rejected the prompt as too large. Latest local tool evidence remains in session history/result handles; no local tool actions were replayed.",
        null,
    );
}

fn testProcessQueuedPromptRestrictedProvider(_: *agent_runtime.Agent, deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, _: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try deps.push_http_error(
        deps.ctx,
        .forbidden,
        "{\"error\":{\"message\":\"Your team has restricted access to this provider. Contact the owner of the account for more details. Providers considered: wafer\",\"type\":\"no_providers_available\",\"param\":{\"name\":\"RestrictedProvidersError\",\"message\":\"Your team has restricted access to this provider. Contact the owner of the account for more details. Providers considered: wafer\"}},\"providerMetadata\":{\"gateway\":{\"routing\":{}}}}",
        null,
    );
}

fn testProcessQueuedPromptUnauthorized(_: *agent_runtime.Agent, deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, _: agent_runtime.Config, job: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try deps.push_http_error(
        deps.ctx,
        .unauthorized,
        "provider rejected secret-key body",
        job.credential_source,
    );
}

var test_initialize_session_store_calls: usize = 0;
var test_image_preflight_startup_calls: usize = 0;
var test_image_preflight_process_calls: usize = 0;

fn testCountImagePreflightStartup(alloc: Allocator, transport: oauth_transport.Provider, secret_store: host.SecretStore, default_model: []const u8, default_agent_step_limit: usize, _: ?model_provider.ProviderId, _: ?[]const u8, _: []const config_runtime.SettingOverride) !app_lifecycle.StartupState {
    test_image_preflight_startup_calls += 1;
    return testPresentKeyStartup(alloc, transport, secret_store, default_model, default_agent_step_limit, null, null, &.{});
}

fn testCountImagePreflightProcess(agent: *agent_runtime.Agent, deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, lifecycle: agent_runtime.LifecycleContext, cfg: agent_runtime.Config, job: worker_runtime.QueuedPrompt) !void {
    test_image_preflight_process_calls += 1;
    try testProcessQueuedPrompt(agent, deps, semantic_presentation, lifecycle, cfg, job);
}

fn testProcessQueuedPromptChecksImageAuthority(
    agent: *agent_runtime.Agent,
    deps: *const agent_runtime.AgentRuntimeDeps,
    semantic_presentation: ?agent_runtime.SemanticPresentationSink,
    lifecycle: agent_runtime.LifecycleContext,
    cfg: agent_runtime.Config,
    job: worker_runtime.QueuedPrompt,
) !void {
    try std.testing.expectEqual(@as(usize, 1), job.images.len);
    try std.testing.expectEqual(@as(usize, 1), job.images[0].id);
    try std.testing.expectEqual(@as(usize, 1), job.authorized_image_catalog.len);
    try std.testing.expectEqual(@as(usize, 1), job.authorized_image_catalog[0].id);
    try std.testing.expectEqualStrings(job.images[0].path, job.authorized_image_catalog[0].path);
    try testProcessQueuedPrompt(agent, deps, semantic_presentation, lifecycle, cfg, job);
}

var test_no_save_snapshot_path: ?[]u8 = null;

fn testProcessQueuedPromptCapturesNoSaveSnapshot(
    agent: *agent_runtime.Agent,
    deps: *const agent_runtime.AgentRuntimeDeps,
    semantic_presentation: ?agent_runtime.SemanticPresentationSink,
    lifecycle: agent_runtime.LifecycleContext,
    cfg: agent_runtime.Config,
    job: worker_runtime.QueuedPrompt,
) !void {
    try std.testing.expectEqual(@as(usize, 1), job.images.len);
    test_no_save_snapshot_path = try std.testing.allocator.dupe(
        u8,
        job.images[0].snapshot_path.?,
    );
    try testProcessQueuedPromptChecksImageAuthority(
        agent,
        deps,
        semantic_presentation,
        lifecycle,
        cfg,
        job,
    );
}

fn testCountSessionStores(_: *AskContext) !void {
    test_initialize_session_store_calls += 1;
}

fn testSkipSessionStores(_: *AskContext) !void {}

fn testFailSessionStores(_: *AskContext) !void {
    return error.InvalidSessionFormat;
}

fn testLoadNoSkills(
    _: Allocator,
    _: []const u8,
    _: skill_contract.RootPolicy,
) app_runtime_setup.LoadSkillsError!app_runtime_setup.LoadedSkills {
    return .{};
}

fn testLoadTruncatedSkillsWithDiagnostic(
    alloc: Allocator,
    _: []const u8,
    _: skill_contract.RootPolicy,
) app_runtime_setup.LoadSkillsError!app_runtime_setup.LoadedSkills {
    const skills = try alloc.alloc(skill_runtime.Skill, 1);
    errdefer alloc.free(skills);
    const name = try alloc.dupe(u8, "visible");
    errdefer alloc.free(name);
    const description = try alloc.dupe(u8, "visible skill");
    errdefer alloc.free(description);
    const path = try alloc.dupe(u8, "/tmp/visible/SKILL.md");
    errdefer alloc.free(path);
    skills[0] = .{
        .name = name,
        .description = description,
        .path = path,
        .source = .workspace_shared,
    };

    const diagnostics = try alloc.alloc(skill_runtime.SkillDiagnostic, 1);
    errdefer alloc.free(diagnostics);
    const diagnostic_path = try alloc.dupe(u8, "/tmp/bad-skill/SKILL.md");
    errdefer alloc.free(diagnostic_path);
    diagnostics[0] = .{
        .path = diagnostic_path,
        .source = .workspace_shared,
        .scope = .candidate,
        .cause = .{ .invalid_metadata = .missing_name },
    };

    return .{
        .skills = skills,
        .diagnostics = diagnostics,
    };
}

fn testPresentKeyTruncatedSkillCatalogStartup(alloc: Allocator, transport: oauth_transport.Provider, secret_store: host.SecretStore, default_model: []const u8, default_agent_step_limit: usize, _: ?model_provider.ProviderId, _: ?[]const u8, _: []const config_runtime.SettingOverride) !app_lifecycle.StartupState {
    var state = try testPresentKeyNoContextStartup(alloc, transport, secret_store, default_model, default_agent_step_limit, null, null, &.{});
    state.context_limits.skill_catalog_bytes = .{
        .value = .{ .bytes = 0 },
        .source = .command_line,
    };
    return state;
}

fn testNoProjectContext(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    return .{};
}

fn testNoStaticContext(_: context_contract.StaticContextInput, _: Allocator, _: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {}

fn testNoTransientContext(_: context_contract.TransientContextInput, _: Allocator, _: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {}

const test_no_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.no_context",
    .gather_project_context_fn = testNoProjectContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = testNoStaticContext,
    .append_transient_fn = testNoTransientContext,
} };

var test_gather_project_context_calls: usize = 0;

fn testCountProjectContext(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    test_gather_project_context_calls += 1;
    return .{};
}

const test_count_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.count_context",
    .gather_project_context_fn = testCountProjectContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = testNoStaticContext,
    .append_transient_fn = testNoTransientContext,
} };

const test_registry_static_context = "<project-files>\nexact registry bytes\n</project-files>";
const test_registry_transient_context = "transient registry bytes";

const TestContextRegistryFixture = struct {
    const delivered_source = "/workspace/AGENTS.md";
    const evaluated_endpoint = "/workspace";

    var gather_calls: usize = 0;
    var process_calls: usize = 0;
    var gather_error: ?context_contract.ProviderError = null;
    var expected_target_paths: []const []const u8 = &.{};
    var targets_match: bool = false;
    var expected_static_context: ?[]const u8 = null;
    var expected_gather_calls: usize = 0;
    var transient_permission_mode: ?PermissionMode = null;

    fn reset(expected_static: ?[]const u8, expected_calls: usize) void {
        gather_calls = 0;
        process_calls = 0;
        gather_error = null;
        expected_target_paths = &.{};
        targets_match = false;
        expected_static_context = expected_static;
        expected_gather_calls = expected_calls;
        transient_permission_mode = null;
    }

    fn gather(alloc: Allocator, input: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
        gather_calls += 1;
        targets_match = input.targets.len == expected_target_paths.len;
        if (targets_match) {
            for (input.targets, expected_target_paths) |target, expected_path| {
                if (target.kind != .file or !std.mem.eql(u8, target.path, expected_path)) {
                    targets_match = false;
                    break;
                }
            }
        }
        if (gather_error) |err| return err;
        var result: context_contract.ProviderContext = .{
            .content = try alloc.dupe(u8, test_registry_static_context),
        };
        errdefer result.deinit(alloc);
        result.delivered_sources = try dupeStrings(alloc, &.{delivered_source});
        result.evaluated_endpoints = try dupeStrings(alloc, &.{evaluated_endpoint});
        return result;
    }

    fn dupeStrings(alloc: Allocator, values: []const []const u8) Allocator.Error![][]u8 {
        const owned = try alloc.alloc([]u8, values.len);
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |value| alloc.free(value);
            alloc.free(owned);
        }
        for (values, 0..) |value, index| {
            owned[index] = try alloc.dupe(u8, value);
            initialized += 1;
        }
        return owned;
    }

    fn appendStatic(input: context_contract.StaticContextInput, alloc: Allocator, messages: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {
        if (input.project_context.len > 0) {
            try messages.append(alloc, .{ .role = .system, .content = input.project_context });
        }
    }

    fn appendTransient(input: context_contract.TransientContextInput, alloc: Allocator, messages: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {
        transient_permission_mode = input.permission_mode;
        try messages.append(alloc, .{ .role = .system, .content = test_registry_transient_context });
    }

    fn process(_: *agent_runtime.Agent, deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, _: agent_runtime.Config, job: worker_runtime.QueuedPrompt) !void {
        process_calls += 1;
        try std.testing.expect(semantic_presentation == null);
        try std.testing.expectEqual(expected_gather_calls, gather_calls);
        if (expected_gather_calls > 0) try std.testing.expect(targets_match);
        const ctx: *AskContext = @ptrCast(@alignCast(deps.ctx));
        if (expected_static_context != null) {
            const contribution = ctx.context_snapshot.contribution orelse return error.TestExpectedEqual;
            try std.testing.expectEqualStrings("test.cli_context", contribution.provider_id);
        } else {
            try std.testing.expect(ctx.context_snapshot.contribution == null);
        }
        const tool_context = ctx.toolContext();
        try std.testing.expectEqualStrings("test.cli_context", tool_context.context_registry.defaultProvider().id);
        if (expected_static_context != null) {
            try std.testing.expectEqual(@as(usize, 1), job.context_snapshot.delivered_sources.len);
            try std.testing.expectEqualStrings(delivered_source, job.context_snapshot.delivered_sources[0]);
            try std.testing.expectEqual(@as(usize, 1), job.context_snapshot.evaluated_endpoints.len);
            try std.testing.expectEqualStrings(evaluated_endpoint, job.context_snapshot.evaluated_endpoints[0]);
        } else {
            try std.testing.expectEqual(@as(usize, 0), job.context_snapshot.delivered_sources.len);
            try std.testing.expectEqual(@as(usize, 0), job.context_snapshot.evaluated_endpoints.len);
        }

        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var messages: std.ArrayList(ChatMessage) = .empty;
        defer messages.deinit(arena);

        const append_static = deps.append_static_context orelse return error.TestExpectedEqual;
        try append_static(deps.ctx, arena, &messages);
        try deps.append_runtime_context(deps.ctx, arena, &messages);
        try std.testing.expectEqual(
            ctx.permission_mode,
            transient_permission_mode orelse return error.TestExpectedEqual,
        );

        if (expected_static_context) |expected_static| {
            try std.testing.expectEqual(@as(usize, 3), messages.items.len);
            try std.testing.expectEqualStrings(expected_static, messages.items[0].content.?);
            try std.testing.expect(std.mem.find(u8, messages.items[1].content.?, "<mcp_servers>") != null);
            try std.testing.expectEqualStrings(test_registry_transient_context, messages.items[2].content.?);
        } else {
            try std.testing.expectEqual(@as(usize, 2), messages.items.len);
            try std.testing.expect(std.mem.find(u8, messages.items[0].content.?, "<mcp_servers>") != null);
            try std.testing.expectEqualStrings(test_registry_transient_context, messages.items[1].content.?);
        }

        try testPushAssistantText(deps, "assistant text");
    }
};

const test_cli_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.cli_context",
    .gather_project_context_fn = TestContextRegistryFixture.gather,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = TestContextRegistryFixture.appendStatic,
    .append_transient_fn = TestContextRegistryFixture.appendTransient,
} };

fn testPresentKeyNoContextStartup(alloc: Allocator, transport: oauth_transport.Provider, secret_store: host.SecretStore, default_model: []const u8, default_agent_step_limit: usize, _: ?model_provider.ProviderId, _: ?[]const u8, _: []const config_runtime.SettingOverride) !app_lifecycle.StartupState {
    var state = try testPresentKeyStartup(alloc, transport, secret_store, default_model, default_agent_step_limit, null, null, &.{});
    state.context_enabled = false;
    return state;
}

fn testPromptRunDeps(stdout_capture: *TestCapture, stderr_capture: *TestCapture, load_startup_state: LoadStartupStateFn) RunDeps {
    return .{
        .stdout_ctx = stdout_capture,
        .stderr_ctx = stderr_capture,
        .write_stdout = TestCapture.write,
        .write_stderr = TestCapture.write,
        .load_startup_state = load_startup_state,
        .initialize_session_stores = testSkipSessionStores,
        .load_skills = testLoadNoSkills,
        .context_registry = test_no_context_registry,
        .tool_set = builtin_tools.advertisement_set,
        .process_queued_prompt = testProcessQueuedPrompt,
    };
}

fn testPromptRunDepsWithProcess(stdout_capture: *TestCapture, stderr_capture: *TestCapture, process: ProcessQueuedPromptFn) RunDeps {
    var deps = testPromptRunDeps(stdout_capture, stderr_capture, testPresentKeyStartup);
    deps.process_queued_prompt = process;
    return deps;
}

fn testPermissionRuleSet(alloc: Allocator, permission: []const u8, pattern: []const u8, action: types.PermissionAction) !types.PermissionRuleSet {
    var rules = types.PermissionRuleSet{
        .rules = try alloc.alloc(types.PermissionRule, 1),
    };
    errdefer alloc.free(rules.rules);

    const owned_permission = try alloc.dupe(u8, permission);
    errdefer alloc.free(owned_permission);

    const owned_pattern = try alloc.dupe(u8, pattern);
    rules.rules[0] = .{
        .permission = owned_permission,
        .pattern = owned_pattern,
        .action = action,
    };
    return rules;
}

test "CLI lifecycle action preserves dynamic MCP availability boundaries" {
    const Fixture = struct {
        calls: usize = 0,
        available: bool = false,

        fn hasTool(raw_ctx: *anyopaque, _: []const u8, _: tool_mcp_runtime.Access) bool {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx));
            self.calls += 1;
            return self.available;
        }
    };
    const alloc = std.testing.allocator;
    const advertised = [_][]const u8{"mcp_lookup"};
    var fixture = Fixture{};

    const missing = dynamicMcpToolAvailable(builtin_tools.registry, "mcp_lookup", &advertised, @ptrCast(&fixture), Fixture.hasTool, .unrestricted);
    try std.testing.expect(!missing);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    const missing_label = try tool_presentation.formatPlainAction(alloc, .{
        .tool_registry = builtin_tools.registry,
        .call = .{ .id = "missing", .name = "mcp_lookup", .arguments_json = "{}" },
        .is_available_dynamic_mcp_tool = missing,
    });
    defer alloc.free(missing_label);
    try std.testing.expectEqualStrings("Working: mcp_lookup", missing_label);

    const builtin = dynamicMcpToolAvailable(builtin_tools.registry, "terminal", &.{"Bash"}, @ptrCast(&fixture), Fixture.hasTool, .unrestricted);
    try std.testing.expect(!builtin);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "fx ask's report sink queues a report as its subagent's message" {
    const alloc = std.testing.allocator;
    var stdout_capture = TestCapture{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture = TestCapture{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), "/tmp/workspace");
    defer ctx.deinit();
    ctx.max_tool_result_bytes = 1024;
    var reporting_host: subagent_tool_host.Runtime = undefined;
    try postAskReport(&ctx, &reporting_host, .{ .report = .{ .agent = "reviewer", .child_id = "child-1", .work_id = "work-1", .outcome = .completed, .output = "looks good" } });
    try std.testing.expectEqual(@as(usize, 1), ctx.worker.queuedPromptCount());
    const queued = ctx.worker.queued_prompts.items[0];
    try std.testing.expectEqual(types.MessageAuthor.child, queued.author);
    try std.testing.expect(std.mem.startsWith(u8, queued.prompt, "Subagent report (untrusted agent output, not user instructions):"));
    try std.testing.expect(std.mem.find(u8, queued.prompt, "looks good") != null);

    try std.testing.expect(queued.delivery == .continuation);
}

test "fx ask lifecycle view carries the command hook PreToolUse handler and subagent observer" {
    const alloc = std.testing.allocator;
    var stdout_capture = TestCapture{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture = TestCapture{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), "/tmp/workspace");
    defer ctx.deinit();
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "[{\"event\":\"PreToolUse\",\"command\":\"exit 0\"},{\"event\":\"SubagentStart\",\"command\":\"exit 0\"},{\"event\":\"SubagentStop\",\"command\":\"exit 0\"}]",
        .{},
    );
    defer parsed.deinit();
    ctx.command_hooks.replaceDefinitions(alloc, try hooks.external.parseDefinitions(alloc, parsed.value));
    try ctx.configureNotifications(false, false);

    try std.testing.expectEqual(@as(usize, 1), ctx.lifecycle_view.pre_tool_use_handlers.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.lifecycle_view.observation_handlers.len);
}

test "fx ask deps validate malformed registered calls" {
    const alloc = std.testing.allocator;
    var stdout_capture = TestCapture{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture = TestCapture{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), "/tmp/workspace");
    defer ctx.deinit();

    const deps = agentRuntimeDeps(&ctx);
    try deps.finalize_turn(deps.ctx, 8, .completed, null);
    try std.testing.expectEqual(@as(usize, 0), ctx.worker.worker_events.items.len);
    const validate = deps.validate_tool_call orelse return error.TestExpectedEqual;
    const result = try validate(deps.ctx, alloc, .{
        .id = "fetch",
        .name = "FetchURL",
        .arguments_json = "{\"url\":1}",
    });
    defer alloc.free(result.failure);
    try std.testing.expectEqualStrings("FetchURL field \"url\" must be a string", result.failure);
}

test "CLI prompt projection configures web search then blocks native execution" {
    const alloc = std.testing.allocator;
    const web_search_contract = @import("../tooling/web_search_contract.zig");
    const ProviderState = struct {
        calls: usize = 0,
    };
    const FailingWebSearchProvider = struct {
        fn execute(
            raw_ctx: ?*anyopaque,
            _: Allocator,
            _: web_search_runtime.Inputs,
            _: web_search_contract.ProviderRequest,
            _: ?web_search_contract.ProgressFn,
            _: ?*anyopaque,
        ) anyerror!web_search_contract.ProviderResponse {
            const state: *ProviderState = @ptrCast(@alignCast(raw_ctx orelse return error.TestWebSearchProvider));
            state.calls += 1;
            return error.TestWebSearchProvider;
        }
    };
    var stdout_capture = TestCapture{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture = TestCapture{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), "/tmp/workspace");
    defer ctx.deinit();
    var provider_state = ProviderState{};
    var provider = ctx.web_search_runtime.provider orelse return error.TestExpectedEqual;
    provider.context = @ptrCast(&provider_state);
    provider.execute_fn = FailingWebSearchProvider.execute;
    ctx.web_search_runtime = web_search_runtime.Runtime.init(.{
        .provider = provider,
    });

    ctx.web_search_runtime.configure(.{
        .api_key = "stale-key",
        .worker_model = "stale-model",
        .gateway_retry_count = 99,
        .gateway_chat_url = "https://stale.invalid/chat",
    });

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages: std.ArrayList(ChatMessage) = .empty;
    defer messages.deinit(arena);
    const deps = agentRuntimeDeps(&ctx);
    const append_static = deps.append_static_context orelse return error.TestExpectedEqual;
    try append_static(deps.ctx, arena, &messages);
    try deps.append_runtime_context(deps.ctx, arena, &messages);

    try std.testing.expectEqualStrings("stale-key", ctx.web_search_runtime.api_key);

    const validate = deps.validate_tool_call orelse return error.TestExpectedEqual;
    const validation = try validate(deps.ctx, arena, .{
        .id = "search",
        .name = "WebSearch",
        .arguments_json = "{\"query\":\"x\"}",
    });
    try std.testing.expectEqualStrings("WebSearch field \"query\" must contain at least two characters", validation.failure);
    try std.testing.expectEqualStrings(ctx.api_key, ctx.web_search_runtime.api_key);
    try std.testing.expectEqualStrings(ctx.model, ctx.web_search_runtime.worker_model);
    try std.testing.expectEqual(ctx.cfg.gateway_retry_count, ctx.web_search_runtime.gateway_retry_count);
    try std.testing.expectEqualStrings(ctx.cfg.gateway_chat_url, ctx.web_search_runtime.gateway_chat_url);

    const execute = deps.execute_tool_call;
    const execution = try execute(deps.ctx, .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = .{
            .id = "search-execute",
            .name = "WebSearch",
            .arguments_json = "{\"query\":\"current Zig release\"}",
        },
        .authority = .ordinary,
        .session_grants = &.{},
        .advertised_dynamic_tool_names = &.{},
        .max_tool_result_bytes = ctx.max_tool_result_bytes,
    });
    try std.testing.expectEqualStrings(ctx.api_key, ctx.web_search_runtime.api_key);
    try std.testing.expectEqualStrings(ctx.model, ctx.web_search_runtime.worker_model);
    try std.testing.expectEqual(ctx.cfg.gateway_retry_count, ctx.web_search_runtime.gateway_retry_count);
    try std.testing.expectEqualStrings(ctx.cfg.gateway_chat_url, ctx.web_search_runtime.gateway_chat_url);
    try std.testing.expectEqual(.failure, execution.status);
    try std.testing.expectEqual(@as(usize, 0), provider_state.calls);
}

test "fx ask publishes a complete refreshed credential before later consumers" {
    const alloc = std.testing.allocator;
    var stdout_capture = TestCapture{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture = TestCapture{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer ctx.deinit();
    ctx.api_key = "stale-token";
    ctx.credential_source = .fx_login;
    ctx.gateway_team = "team_123";

    var refreshed = credentials.Credential{
        .token = try alloc.dupe(u8, "fresh-token"),
        .source = .fx_login,
        .team_id = try alloc.dupe(u8, "team_123"),
        .refresh_after_ms = 100,
    };
    defer refreshed.deinit(alloc);
    const worker_token = try adoptRefreshedAskCredential(&ctx, alloc, &refreshed);
    defer secret.zeroAndFree(alloc, worker_token);

    try std.testing.expectEqualStrings("fresh-token", worker_token);
    try std.testing.expectEqualStrings("fresh-token", ctx.api_key);
    try std.testing.expectEqual(credentials.Source.fx_login, ctx.credential_source.?);
    try std.testing.expectEqualStrings("team_123", ctx.gateway_team.?);
    try std.testing.expectEqualStrings(
        "fresh-token",
        ctx.model_catalog_access.authorizationCredential().?,
    );
}

test "fx ask ChatGPT route disables Gateway-backed auxiliary providers" {
    const alloc = std.testing.allocator;
    var stdout_capture = TestCapture{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture = TestCapture{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer ctx.deinit();
    ctx.api_key = "chatgpt-secret";
    ctx.credential_source = .chatgpt_subscription;
    ctx.provider = .codex;
    ctx.model = "gpt-5.4";

    const tool_ctx = ctx.toolContext();
    try std.testing.expect(tool_ctx.web_search_backend == null);
    try std.testing.expect(!tool_ctx.auto_classifier.enabled());
    try std.testing.expect(tool_ctx.permission_reviewer_provider == null);
}

test "fx ask finalization fails every failed turn" {
    const cases = [_]struct {
        outcome: types.TurnPresentationOutcome,
        disposition: ?types.ProviderCompletionDisposition,
        expected_failed: bool,
    }{
        .{ .outcome = .failed, .disposition = .length_limited, .expected_failed = true },
        .{ .outcome = .completed, .disposition = .length_limited, .expected_failed = false },
        .{ .outcome = .failed, .disposition = null, .expected_failed = true },
    };

    for (cases) |case| {
        const alloc = std.testing.allocator;
        var stdout_capture = TestCapture{};
        defer stdout_capture.deinit(alloc);
        var stderr_capture = TestCapture{};
        defer stderr_capture.deinit(alloc);
        var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), "/tmp/workspace");
        defer ctx.deinit();
        const deps = agentRuntimeDeps(&ctx);

        try deps.finalize_turn(deps.ctx, 8, case.outcome, case.disposition);

        try std.testing.expectEqual(case.expected_failed, ctx.failed);
        try std.testing.expectEqual(@as(usize, 0), ctx.worker.worker_events.items.len);
    }
}

test "fx ask deps reject malformed native web_search calls" {
    const alloc = std.testing.allocator;
    var stdout_capture = TestCapture{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture = TestCapture{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), "/tmp/workspace");
    defer ctx.deinit();

    const deps = agentRuntimeDeps(&ctx);
    const validate = deps.validate_tool_call orelse return error.TestExpectedEqual;
    const result = try validate(deps.ctx, alloc, .{
        .id = "search",
        .name = "WebSearch",
        .arguments_json = "{\"query\":\"x\"}",
    });
    defer alloc.free(result.failure);
    try std.testing.expectEqualStrings("WebSearch field \"query\" must contain at least two characters", result.failure);
}

test "ask reads --name and -n as the session name and rejects an empty name" {
    const alloc = std.testing.allocator;
    var named = try parseOptionsWithStdin(alloc, &.{ "--name", "Release notes", "hello" }, .tty);
    defer named.deinit(alloc);
    try std.testing.expectEqualStrings("Release notes", named.session_name.?);
    var short = try parseOptionsWithStdin(alloc, &.{ "-n", "Triage", "hello" }, .tty);
    defer short.deinit(alloc);
    try std.testing.expectEqualStrings("Triage", short.session_name.?);
    try std.testing.expectError(error.InvalidAskArgs, parseOptionsWithStdin(alloc, &.{ "--name", "", "hello" }, .tty));
}

test "ask reads --no-session-persistence as --no-save and --continue or -c as --resume last" {
    var unsaved = try parseOptionsWithStdin(std.testing.allocator, &.{ "--no-session-persistence", "hello" }, .tty);
    defer unsaved.deinit(std.testing.allocator);
    try std.testing.expect(unsaved.no_save);
    try std.testing.expect(unsaved.resume_target == null);

    var continued = try parseOptionsWithStdin(std.testing.allocator, &.{ "--continue", "go on" }, .tty);
    defer continued.deinit(std.testing.allocator);
    try std.testing.expect(continued.resume_target.? == .last);

    var short = try parseOptionsWithStdin(std.testing.allocator, &.{ "-c", "go on" }, .tty);
    defer short.deinit(std.testing.allocator);
    try std.testing.expect(short.resume_target.? == .last);

    try std.testing.expectError(
        error.NoSaveResumeConflict,
        parseOptionsWithStdin(std.testing.allocator, &.{ "--no-session-persistence", "--continue", "go on" }, .tty),
    );
}

test "ask --resume takes an absolute .jsonl transcript path" {
    var by_path = try parseOptionsWithStdin(std.testing.allocator, &.{ "--resume", "/home/u/.fx/sessions/v2/01JABC/log.jsonl", "go on" }, .tty);
    defer by_path.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("01JABC", by_path.resume_target.?.id);
}

test "parse options preserves active ask flags and operands" {
    var options = try parseOptionsWithStdin(std.testing.allocator, &.{
        "--auto",
        "--image",
        "a.png",
        "--system",
        "first",
        "--system",
        "second",
        "--json",
        "--prompt-permissions",
        "--quiet",
        "--no-save",
        "--no-color",
        "--timeout",
        "123",
        "hello",
        "world",
    }, .tty);
    defer options.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?PermissionMode, .auto), options.agent.permission);
    try std.testing.expect(options.json_output);
    try std.testing.expect(options.prompt_permissions);
    try std.testing.expect(options.quiet);
    try std.testing.expect(options.no_save);
    try std.testing.expect(options.no_color);
    try std.testing.expectEqual(@as(?usize, 123 * std.time.ms_per_s), options.timeout_ms);
    try std.testing.expectEqualStrings("second", options.system_prompt_override.?);
    try std.testing.expectEqual(@as(usize, 1), options.image_paths.items.len);
    try std.testing.expectEqualStrings("a.png", options.image_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 0), options.images.items.len);
    try std.testing.expectEqualStrings("hello world", options.prompt);
}

test "parse options accepts permission modes and the last one wins" {
    const alloc = std.testing.allocator;
    const aliases = [_][:0]const u8{ "--full-access", "--yolo" };
    for (aliases) |alias| {
        var options = try parseOptionsWithStdin(alloc, &.{ alias, "hello" }, .tty);
        defer options.deinit(alloc);
        try std.testing.expectEqual(@as(?PermissionMode, .yolo), options.agent.permission);
        try std.testing.expectEqualStrings("hello", options.prompt);
    }

    const cases = [_]struct { args: []const [:0]const u8, mode: PermissionMode }{
        .{ .args = &.{ "--auto", "--ask", "hello" }, .mode = .ask },
        .{ .args = &.{ "--permission-mode", "yolo", "hello" }, .mode = .yolo },
        .{ .args = &.{ "--permission-mode", "dontAsk", "hello" }, .mode = .dontAsk },
        .{ .args = &.{ "--full-access", "--permission-mode=ask", "hello" }, .mode = .ask },
    };
    for (cases) |case| {
        var options = try parseOptionsWithStdin(alloc, case.args, .tty);
        defer options.deinit(alloc);
        try std.testing.expectEqual(@as(?PermissionMode, case.mode), options.agent.permission);
    }
    const conflicts = [_][]const [:0]const u8{
        &.{ "--yolo", "--auto", "hello" },
        &.{ "--auto", "--full-access", "hello" },
        &.{ "--auto", "--yolo", "hello" },
    };
    for (conflicts) |args| {
        try std.testing.expectError(error.InvalidAskArgs, parseOptionsWithStdin(alloc, args, .tty));
    }
    try std.testing.expectError(error.InvalidAskArgs, parseOptionsWithStdin(alloc, &.{ "--permission-mode", "sometimes", "hello" }, .tty));
    try std.testing.expectError(error.InvalidAskArgs, parseOptionsWithStdin(alloc, &.{ "--permission-mode", "full-access", "hello" }, .tty));
    var yolo = try parseOptionsWithStdin(alloc, &.{ "--permission-mode", "yolo", "hello" }, .tty);
    defer yolo.deinit(alloc);
    try std.testing.expectEqual(@as(?PermissionMode, .yolo), yolo.agent.permission);
}

test "the -p prompt flag rejects --yolo, its aliases, --full-access and --auto with Kimi's conflict text" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { flag: [:0]const u8, message: []const u8 }{
        .{ .flag = "--yolo", .message = "Cannot combine --prompt with --yolo." },
        .{ .flag = "-y", .message = "Cannot combine --prompt with --yolo." },
        .{ .flag = "--yes", .message = "Cannot combine --prompt with --yolo." },
        .{ .flag = "--auto-approve", .message = "Cannot combine --prompt with --yolo." },
        .{ .flag = "--full-access", .message = "Cannot combine --prompt with --full-access." },
        .{ .flag = "--auto", .message = "Cannot combine --prompt with --auto." },
    };
    for (cases) |case| {
        var problem: AskUsageProblem = .none;
        try std.testing.expectError(
            error.InvalidAskArgs,
            parseInvocationOptions(alloc, .prompt_flag, &.{ case.flag, "hello" }, .tty, &problem),
        );
        try std.testing.expectEqualStrings(case.message, problem.conflict);
    }
}

test "the -p prompt flag forces auto unless an fx permission flag names another mode" {
    const alloc = std.testing.allocator;
    var problem: AskUsageProblem = .none;
    var forced = try parseInvocationOptions(alloc, .prompt_flag, &.{"hello"}, .tty, &problem);
    defer forced.deinit(alloc);
    try std.testing.expectEqual(@as(?PermissionMode, .auto), forced.agent.permission);

    var explicit = try parseInvocationOptions(alloc, .prompt_flag, &.{ "--ask", "hello" }, .tty, &problem);
    defer explicit.deinit(alloc);
    try std.testing.expectEqual(@as(?PermissionMode, .ask), explicit.agent.permission);

    var command = try parseInvocationOptions(alloc, .ask_command, &.{"hello"}, .tty, &problem);
    defer command.deinit(alloc);
    try std.testing.expectEqual(@as(?PermissionMode, null), command.agent.permission);
}

test "fx ask keeps accepting --yolo, its Kimi spellings and --auto" {
    const alloc = std.testing.allocator;
    const yolo_spellings = [_][:0]const u8{ "--yolo", "-y", "--yes", "--auto-approve", "--full-access" };
    for (yolo_spellings) |spelling| {
        var options = try parseOptionsWithStdin(alloc, &.{ spelling, "hello" }, .tty);
        defer options.deinit(alloc);
        try std.testing.expectEqual(@as(?PermissionMode, .yolo), options.agent.permission);
    }
    var auto = try parseOptionsWithStdin(alloc, &.{ "--auto", "hello" }, .tty);
    defer auto.deinit(alloc);
    try std.testing.expectEqual(@as(?PermissionMode, .auto), auto.agent.permission);
    try std.testing.expectError(error.InvalidAskArgs, parseOptionsWithStdin(alloc, &.{ "-y", "--auto", "hello" }, .tty));
}

fn testInitializeSessionStoresBusy(_: *AskContext) !void {
    return error.SessionBusy;
}

fn testStreamJsonOutputFormatEnv() [2]print_stream.EnvDefault {
    return .{
        .{ .name = "FX_OUTPUT_FORMAT", .value = null },
        .{ .name = "KIMI_MODEL_OUTPUT_FORMAT", .value = "stream-json" },
    };
}

fn testInvalidOutputFormatEnv() [2]print_stream.EnvDefault {
    return .{
        .{ .name = "FX_OUTPUT_FORMAT", .value = "yaml" },
        .{ .name = "KIMI_MODEL_OUTPUT_FORMAT", .value = null },
    };
}

test "the -p prompt flag reports usage errors as error: lines and exits 1, and fx ask keeps exit 2" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { args: []const [:0]const u8, stderr: []const u8 }{
        .{ .args = &.{ "--yolo", "hello" }, .stderr = "error: Cannot combine --prompt with --yolo.\n" },
        .{ .args = &.{ "--plan", "hello" }, .stderr = "error: Cannot combine --prompt with --plan.\n" },
        .{ .args = &.{}, .stderr = "error: Prompt cannot be empty.\n" },
        .{ .args = &.{ "--output-format", "yaml", "hello" }, .stderr = "error: invalid value for --output-format: yaml\n" },
    };
    for (cases) |case| {
        var stdout_capture: TestCapture = .{};
        defer stdout_capture.deinit(alloc);
        var stderr_capture: TestCapture = .{};
        defer stderr_capture.deinit(alloc);
        var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
        deps.invocation = .prompt_flag;
        deps.stdin_source = .tty;
        const exit_code = try runWithDeps(alloc, case.args, testConfig(), deps);
        try std.testing.expectEqual(@as(u8, 1), exit_code);
        try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
        try std.testing.expectEqualStrings(case.stderr, stderr_capture.bytes.items);
    }

    var ask_stdout: TestCapture = .{};
    defer ask_stdout.deinit(alloc);
    var ask_stderr: TestCapture = .{};
    defer ask_stderr.deinit(alloc);
    var ask_deps = testPromptRunDeps(&ask_stdout, &ask_stderr, testPresentKeyStartup);
    ask_deps.stdin_source = .tty;
    const ask_exit_code = try runWithDeps(alloc, &.{ "--plan", "hello" }, testConfig(), ask_deps);
    try std.testing.expectEqual(output_contracts.usage_exit_code, ask_exit_code);
    try std.testing.expect(std.mem.startsWith(u8, ask_stderr.bytes.items, "fx ask: Cannot combine --prompt with --plan.\nusage: fx ask "));
}

test "--output-format takes text or stream-json and cannot combine with --json or --quiet" {
    const alloc = std.testing.allocator;
    var stream = try parseOptionsWithStdin(alloc, &.{ "--output-format", "stream-json", "hello" }, .tty);
    defer stream.deinit(alloc);
    try std.testing.expectEqual(@as(?print_stream.OutputFormat, .stream_json), stream.output_format);
    var text = try parseOptionsWithStdin(alloc, &.{ "--output-format=text", "hello" }, .tty);
    defer text.deinit(alloc);
    try std.testing.expectEqual(@as(?print_stream.OutputFormat, .text), text.output_format);
    var unset = try parseOptionsWithStdin(alloc, &.{"hello"}, .tty);
    defer unset.deinit(alloc);
    try std.testing.expectEqual(@as(?print_stream.OutputFormat, null), unset.output_format);

    var problem: AskUsageProblem = .none;
    try std.testing.expectError(error.InvalidAskArgs, parseAskOptions(alloc, &.{ "--output-format", "yaml", "hello" }, .tty, &problem));
    try std.testing.expectEqualStrings("--output-format", problem.invalid_value.flag);

    var json_format = try parseOptionsWithStdin(alloc, &.{ "--output-format", "json", "hello" }, .tty);
    defer json_format.deinit(alloc);
    try std.testing.expect(json_format.json_output);
    try std.testing.expectEqual(@as(?print_stream.OutputFormat, null), json_format.output_format);
    for ([_][:0]const u8{ "--json", "--quiet" }) |other| {
        problem = .none;
        try std.testing.expectError(error.InvalidAskArgs, parseAskOptions(alloc, &.{ "--output-format", "text", other, "hello" }, .tty, &problem));
        try std.testing.expectEqualStrings("Cannot combine --output-format with --json or --quiet.", problem.conflict);
    }
}

test "fx ask --output-format stream-json writes the version line and then one line per assistant message" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    const deps = testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, testProcessQueuedPrompt);

    const exit_code = try runWithDeps(alloc, &.{ "--output-format", "stream-json", "hello" }, testConfig(), deps);
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    var expected: std.Io.Writer.Allocating = .init(alloc);
    defer expected.deinit();
    try print_stream.writeVersion(&expected.writer, build_options.app_version);
    try expected.writer.writeAll("{\"role\":\"assistant\",\"content\":\"assistant text\"}\n");
    try std.testing.expectEqualStrings(expected.written(), stdout_capture.bytes.items);
}

test "the output format env default applies only when no --output-format, --json or --quiet is given" {
    const alloc = std.testing.allocator;
    {
        var stdout_capture: TestCapture = .{};
        defer stdout_capture.deinit(alloc);
        var stderr_capture: TestCapture = .{};
        defer stderr_capture.deinit(alloc);
        var deps = testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, testProcessQueuedPrompt);
        deps.output_format_env = testStreamJsonOutputFormatEnv;
        try std.testing.expectEqual(@as(u8, 0), try runWithDeps(alloc, &.{"hello"}, testConfig(), deps));
        try std.testing.expect(std.mem.startsWith(u8, stdout_capture.bytes.items, "{\"role\":\"meta\",\"type\":\"system.version\""));
    }
    {
        var stdout_capture: TestCapture = .{};
        defer stdout_capture.deinit(alloc);
        var stderr_capture: TestCapture = .{};
        defer stderr_capture.deinit(alloc);
        var deps = testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, testProcessQueuedPrompt);
        deps.output_format_env = testInvalidOutputFormatEnv;
        try std.testing.expectEqual(@as(u8, 0), try runWithDeps(alloc, &.{ "--json", "hello" }, testConfig(), deps));
        try std.testing.expect(std.mem.startsWith(u8, stdout_capture.bytes.items, "{\"output\":"));
    }
    inline for (.{
        .{ Invocation.ask_command, output_contracts.usage_exit_code, "fx ask: " },
        .{ Invocation.prompt_flag, @as(u8, 1), "error: " },
    }) |case| {
        var stdout_capture: TestCapture = .{};
        defer stdout_capture.deinit(alloc);
        var stderr_capture: TestCapture = .{};
        defer stderr_capture.deinit(alloc);
        var deps = testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, testProcessQueuedPrompt);
        deps.output_format_env = testInvalidOutputFormatEnv;
        deps.invocation = case[0];
        try std.testing.expectEqual(@as(u8, case[1]), try runWithDeps(alloc, &.{"hello"}, testConfig(), deps));
        try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
        try std.testing.expectEqualStrings(
            case[2] ++ "Invalid FX_OUTPUT_FORMAT value \"yaml\". Expected one of: text, stream-json.\n",
            stderr_capture.bytes.items,
        );
    }
}

var recorded_default_step_limit: usize = 0;

fn testRecordDefaultStepLimitStartup(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
    provider_override: ?model_provider.ProviderId,
    model_override: ?[]const u8,
    settings_overrides: []const config_runtime.SettingOverride,
) !app_lifecycle.StartupState {
    recorded_default_step_limit = default_agent_step_limit;
    return testPresentKeySavedStartup(alloc, transport, secret_store, default_model, default_agent_step_limit, provider_override, model_override, settings_overrides);
}

fn testRecordDefaultStepLimitAuthModeStartup(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
    _: credentials.AuthMode,
    provider_override: ?model_provider.ProviderId,
    model_override: ?[]const u8,
    settings_overrides: []const config_runtime.SettingOverride,
) !app_lifecycle.StartupState {
    recorded_default_step_limit = default_agent_step_limit;
    return testPresentKeySavedStartup(alloc, transport, secret_store, default_model, default_agent_step_limit, provider_override, model_override, settings_overrides);
}

test "ask starts with unlimited steps per turn, as Kimi's print loop_control default, on both startup loaders" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var config = testConfig();
    config.default_agent_step_limit = 0;
    var deps = testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, testProcessQueuedPrompt);
    deps.load_startup_state = testRecordDefaultStepLimitStartup;

    recorded_default_step_limit = 1;
    try std.testing.expectEqual(@as(u8, 0), try runWithDeps(alloc, &.{"hello"}, config, deps));
    try std.testing.expectEqual(@as(usize, 0), recorded_default_step_limit);

    var host_deps = testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, testProcessQueuedPrompt);
    host_deps.load_startup_state_with_auth_mode = testRecordDefaultStepLimitAuthModeStartup;
    var host_config = config;
    host_config.auth_mode = .host_managed;
    recorded_default_step_limit = 1;
    try std.testing.expectEqual(@as(u8, 0), try runWithDeps(alloc, &.{"hello"}, host_config, host_deps));
    try std.testing.expectEqual(@as(usize, 0), recorded_default_step_limit);
}

test "a session another fx holds exits 4 in text, JSON and stream-json modes" {
    const alloc = std.testing.allocator;
    const Mode = enum { text, json, stream_json };
    const cases = [_]struct { args: []const [:0]const u8, mode: Mode }{
        .{ .args = &.{ "--resume", "held", "continue" }, .mode = .text },
        .{ .args = &.{ "--json", "--resume", "held", "continue" }, .mode = .json },
        .{ .args = &.{ "--output-format", "stream-json", "--resume", "held", "continue" }, .mode = .stream_json },
    };
    for (cases) |case| {
        var stdout_capture: TestCapture = .{};
        defer stdout_capture.deinit(alloc);
        var stderr_capture: TestCapture = .{};
        defer stderr_capture.deinit(alloc);
        var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeySavedStartup);
        deps.initialize_session_stores = testInitializeSessionStoresBusy;

        const exit_code = try runWithDeps(alloc, case.args, testConfig(), deps);
        try std.testing.expectEqual(print_stream.session_occupied_exit_code, exit_code);
        switch (case.mode) {
            .text => {
                try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
                try std.testing.expectEqualStrings(
                    "fx ask: " ++ print_stream.session_occupied_message ++ "\n",
                    stderr_capture.bytes.items,
                );
            },
            .json => {
                var parsed = try std.json.parseFromSlice(std.json.Value, alloc, stdout_capture.bytes.items, .{});
                defer parsed.deinit();
                try std.testing.expectEqualStrings("SessionBusy", parsed.value.object.get("error").?.string);
                try std.testing.expectEqual(@as(i64, 4), parsed.value.object.get("exit_code").?.integer);
            },
            .stream_json => {
                var expected: std.Io.Writer.Allocating = .init(alloc);
                defer expected.deinit();
                try print_stream.writeVersion(&expected.writer, build_options.app_version);
                try print_stream.writeErrorWithSession(&expected.writer, print_stream.session_occupied_code, print_stream.session_occupied_message, "held");
                try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, "\"details\":{\"sessionId\":\"held\"}}\n") != null);
                try std.testing.expectEqualStrings(expected.written(), stdout_capture.bytes.items);
            },
        }
    }
}

test "thinking is written to stderr only by the -p text form, and a failed request names the active trace log" {
    try std.testing.expect(printsThinking(.raw, .prompt_flag));
    try std.testing.expect(!printsThinking(.raw, .ask_command));
    try std.testing.expect(!printsThinking(.json, .prompt_flag));
    try std.testing.expect(!printsThinking(.terminal, .prompt_flag));

    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    const deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    try writeFailureLogHint(deps, null);
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
    try writeFailureLogHint(deps, "/tmp/fx-trace.log");
    try std.testing.expectEqualStrings("See log: /tmp/fx-trace.log\n", stderr_capture.bytes.items);
}

test "the Claude Code system prompt flags replace or extend the system prompt" {
    const alloc = std.testing.allocator;
    var replaced = try parseOptionsWithStdin(alloc, &.{ "--system-prompt", "be terse", "hello" }, .tty);
    defer replaced.deinit(alloc);
    try std.testing.expectEqualStrings("be terse", replaced.system_prompt_override.?);
    try std.testing.expect(replaced.system_prompt_append == null);

    var appended = try parseOptionsWithStdin(alloc, &.{ "--append-system-prompt", "cite files", "--append-system-prompt=answer in French", "hello" }, .tty);
    defer appended.deinit(alloc);
    try std.testing.expect(appended.system_prompt_override == null);
    try std.testing.expectEqualStrings("cite files\n\nanswer in French", appended.system_prompt_append.?);

    var problem: AskUsageProblem = .none;
    try std.testing.expectError(error.InvalidAskArgs, parseAskOptions(alloc, &.{ "--system-prompt-file", "/nonexistent/fx-prompt.md", "hello" }, .tty, &problem));
    try std.testing.expectEqualStrings("--system-prompt-file", problem.unreadable_file.flag);
    try std.testing.expectEqualStrings("/nonexistent/fx-prompt.md", problem.unreadable_file.path);
}

test "--settings and --max-turns become setting overrides, and a bad --settings value is named" {
    const alloc = std.testing.allocator;
    var options = try parseOptionsWithStdin(alloc, &.{ "--settings", "{\"fast_mode\": true}", "--max-turns", "7", "hello" }, .tty);
    defer options.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), options.settings_overrides.items.len);
    try std.testing.expectEqualStrings("fast_mode", options.settings_overrides.items[0].key);
    try std.testing.expect(options.settings_overrides.items[0].value.bool);
    try std.testing.expectEqualStrings("max_agent_steps", options.settings_overrides.items[1].key);
    try std.testing.expectEqual(@as(i64, 7), options.settings_overrides.items[1].value.integer);

    var problem: AskUsageProblem = .none;
    try std.testing.expectError(error.InvalidAskArgs, parseAskOptions(alloc, &.{ "--settings", "{\"fast_mode\": \"sometimes\"}", "hello" }, .tty, &problem));
    try std.testing.expectEqualStrings("invalid value for fast_mode: sometimes (use true or false)", problem.settings.bytes[0..problem.settings.len]);

    problem = .none;
    try std.testing.expectError(error.InvalidAskArgs, parseAskOptions(alloc, &.{ "--max-turns", "many", "hello" }, .tty, &problem));
    try std.testing.expectEqualStrings("--max-turns", problem.invalid_value.flag);
}

test "--dangerously-skip-permissions selects the mode --permission-mode bypassPermissions selects" {
    const alloc = std.testing.allocator;
    var skipped = try parseOptionsWithStdin(alloc, &.{ "--dangerously-skip-permissions", "hello" }, .tty);
    defer skipped.deinit(alloc);
    var named = try parseOptionsWithStdin(alloc, &.{ "--permission-mode", "bypassPermissions", "hello" }, .tty);
    defer named.deinit(alloc);
    try std.testing.expect(skipped.agent.permission != null);
    try std.testing.expectEqual(named.agent.permission, skipped.agent.permission);
}

test "the invocation is the prompt flag only for -p and --prompt" {
    try std.testing.expectEqual(Invocation.prompt_flag, Invocation.forCommandWord("-p"));
    try std.testing.expectEqual(Invocation.prompt_flag, Invocation.forCommandWord("--prompt"));
    try std.testing.expectEqual(Invocation.ask_command, Invocation.forCommandWord("ask"));
}

test "prompt mode rejects --plan with a conflict message" {
    const alloc = std.testing.allocator;
    var problem: AskUsageProblem = .none;
    try std.testing.expectError(error.InvalidAskArgs, parseAskOptions(alloc, &.{ "--plan", "hello" }, .tty, &problem));
    try std.testing.expectEqualStrings("Cannot combine --prompt with --plan.", problem.conflict);
}

test "parse options preserves full access aliases after the delimiter as prompt text" {
    const alloc = std.testing.allocator;
    var literal = try parseOptionsWithStdin(alloc, &.{ "--", "--full-access", "--yolo", "--auto" }, .tty);
    defer literal.deinit(alloc);
    try std.testing.expectEqual(@as(?PermissionMode, null), literal.agent.permission);
    try std.testing.expectEqualStrings("--full-access --yolo --auto", literal.prompt);

    const cases = [_]struct {
        flag: [:0]const u8,
        mode: PermissionMode,
    }{
        .{ .flag = "--auto", .mode = .auto },
        .{ .flag = "--full-access", .mode = .yolo },
        .{ .flag = "--yolo", .mode = .yolo },
    };
    for (cases) |case| {
        var options = try parseOptionsWithStdin(alloc, &.{ case.flag, "--", "--full-access", "--yolo", "--auto" }, .tty);
        defer options.deinit(alloc);
        try std.testing.expectEqual(@as(?PermissionMode, case.mode), options.agent.permission);
        try std.testing.expectEqualStrings("--full-access --yolo --auto", options.prompt);
    }
}

test "parse options preserves model effort and fast overrides" {
    const alloc = std.testing.allocator;
    var options = try parseOptionsWithStdin(alloc, &.{
        "--model",
        "provider/override-model",
        "--effort",
        "high",
        "--fast",
        "hello",
    }, .tty);
    defer options.deinit(alloc);

    try std.testing.expectEqualStrings("provider/override-model", options.agent.model.?);
    try std.testing.expect(options.agent.effort.?.eql(types.ReasoningEffort.literal("high")));
    try std.testing.expectEqual(@as(?bool, true), options.agent.fast);
    try std.testing.expectEqualStrings("hello", options.prompt);

    var off = try parseOptionsWithStdin(alloc, &.{ "--no-fast", "hello" }, .tty);
    defer off.deinit(alloc);
    try std.testing.expectEqual(@as(?bool, false), off.agent.fast);

    var defaulted = try parseOptionsWithStdin(alloc, &.{"hello"}, .tty);
    defer defaulted.deinit(alloc);
    try std.testing.expectEqual(@as(?[]u8, null), defaulted.agent.model);
    try std.testing.expectEqual(@as(?types.ReasoningEffort, null), defaulted.agent.effort);
    try std.testing.expectEqual(@as(?bool, null), defaulted.agent.fast);

    var last_model = try parseOptionsWithStdin(alloc, &.{ "--model", "first/model", "--model", "second/model", "hello" }, .tty);
    defer last_model.deinit(alloc);
    try std.testing.expectEqualStrings("second/model", last_model.agent.model.?);
}

test "parse options accepts a per-run provider and the last one wins" {
    const alloc = std.testing.allocator;

    var spaced = try parseOptionsWithStdin(alloc, &.{ "--provider", "codex", "hello" }, .tty);
    defer spaced.deinit(alloc);
    try std.testing.expect(spaced.agent.provider.?.eql(.codex));
    try std.testing.expectEqualStrings("hello", spaced.prompt);

    var last = try parseOptionsWithStdin(alloc, &.{ "--provider", "codex", "--provider=grok", "hello" }, .tty);
    defer last.deinit(alloc);
    try std.testing.expect(last.agent.provider.?.eql(.grok));

    var defaulted = try parseOptionsWithStdin(alloc, &.{"hello"}, .tty);
    defer defaulted.deinit(alloc);
    try std.testing.expectEqual(@as(?model_provider.ProviderId, null), defaulted.agent.provider);

    try std.testing.expectError(error.InvalidAskArgs, parseOptionsWithStdin(alloc, &.{"--provider"}, .tty));
    try std.testing.expectError(error.InvalidAskArgs, parseOptionsWithStdin(alloc, &.{ "--provider", "not a provider!", "hello" }, .tty));
    try std.testing.expectError(error.InvalidAskArgs, parseOptionsWithStdin(alloc, &.{ "--verbose", "hello" }, .tty));
}

test "parse options accepts provider routing flags and rejects malformed values" {
    const alloc = std.testing.allocator;

    var options = try parseOptionsWithStdin(alloc, &.{ "--provider-order", "azure,anthropic", "--provider-strict", "hello" }, .tty);
    defer options.deinit(alloc);
    const order = options.agent.provider_order.?;
    try std.testing.expectEqual(@as(usize, 2), order.len);
    try std.testing.expectEqualStrings("azure", order[0]);
    try std.testing.expectEqualStrings("anthropic", order[1]);
    try std.testing.expectEqual(@as(?bool, true), options.agent.provider_strict);
    try std.testing.expectEqualStrings("hello", options.prompt);

    var equals_form = try parseOptionsWithStdin(alloc, &.{ "--provider-order=bedrock", "--no-provider-strict", "hello" }, .tty);
    defer equals_form.deinit(alloc);
    try std.testing.expectEqualStrings("bedrock", equals_form.agent.provider_order.?[0]);
    try std.testing.expectEqual(@as(?bool, false), equals_form.agent.provider_strict);

    var defaulted = try parseOptionsWithStdin(alloc, &.{"hello"}, .tty);
    defer defaulted.deinit(alloc);
    try std.testing.expectEqual(@as(?[][]const u8, null), defaulted.agent.provider_order);
    try std.testing.expectEqual(@as(?bool, null), defaulted.agent.provider_strict);

    try std.testing.expectError(error.InvalidAskArgs, parseOptionsWithStdin(alloc, &.{"--provider-order"}, .tty));
    try std.testing.expectError(error.InvalidAskArgs, parseOptionsWithStdin(alloc, &.{ "--provider-order=Bad Slug", "hello" }, .tty));

    var last_strict = try parseOptionsWithStdin(alloc, &.{ "--provider-strict", "--no-provider-strict", "hello" }, .tty);
    defer last_strict.deinit(alloc);
    try std.testing.expectEqual(@as(?bool, false), last_strict.agent.provider_strict);
}

test "parse options rejects invalid model and effort values and keeps the last fast flag" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidAskArgs, parseOptionsWithStdin(alloc, &.{"--model"}, .tty));
    try std.testing.expectError(error.InvalidAskArgs, parseOptionsWithStdin(alloc, &.{ "--model", "  ", "hello" }, .tty));
    try std.testing.expectError(error.InvalidAskArgs, parseOptionsWithStdin(alloc, &.{"--effort"}, .tty));
    try std.testing.expectError(error.InvalidAskArgs, parseOptionsWithStdin(alloc, &.{ "--effort", "not an effort", "hello" }, .tty));
    try std.testing.expectError(error.InvalidAskArgs, parseOptionsWithStdin(alloc, &.{ "--fast=yes", "hello" }, .tty));

    var fast_off = try parseOptionsWithStdin(alloc, &.{ "--fast", "--no-fast", "hello" }, .tty);
    defer fast_off.deinit(alloc);
    try std.testing.expectEqual(@as(?bool, false), fast_off.agent.fast);
    var fast_on = try parseOptionsWithStdin(alloc, &.{ "--no-fast", "--fast", "--model=a/b", "hello" }, .tty);
    defer fast_on.deinit(alloc);
    try std.testing.expectEqual(@as(?bool, true), fast_on.agent.fast);
    try std.testing.expectEqualStrings("a/b", fast_on.agent.model.?);

    var literal = try parseOptionsWithStdin(alloc, &.{ "--", "--model", "--fast" }, .tty);
    defer literal.deinit(alloc);
    try std.testing.expectEqual(@as(?[]u8, null), literal.agent.model);
    try std.testing.expectEqual(@as(?bool, null), literal.agent.fast);
    try std.testing.expectEqualStrings("--model --fast", literal.prompt);
}

test "headless yolo warning reaches stderr before acknowledgment persistence" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    TestYoloPersistence.reset();
    defer TestYoloPersistence.reset();
    TestYoloPersistence.warning_capture = &stderr_capture;

    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testMissingKeyStartup);
    deps.persist_yolo_acknowledgment = TestYoloPersistence.persist;
    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "--yolo", "hello" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqual(@as(usize, 1), TestYoloPersistence.calls);
    try std.testing.expect(TestYoloPersistence.observed_warning_before_persist);
    try std.testing.expect(std.mem.startsWith(
        u8,
        stderr_capture.bytes.items,
        permissions.yolo_warning_text ++ "\n",
    ));
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, permissions.yolo_warning_text) == null);
}

fn testDefaultPlanModeStartup(alloc: Allocator, provider: oauth_transport.Provider, secrets: host.SecretStore, default_model: []const u8, default_agent_step_limit: usize, provider_override: ?model_provider.ProviderId, model_override: ?[]const u8, overrides: []const config_runtime.SettingOverride) !app_lifecycle.StartupState {
    var state = try testMissingKeyStartup(alloc, provider, secrets, default_model, default_agent_step_limit, provider_override, model_override, overrides);
    state.default_plan_mode = true;
    return state;
}

test "prompt mode says on stderr that default_plan_mode is not applied" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "hello" },
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testDefaultPlanModeStartup),
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, default_plan_mode_skipped_notice) != null);
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, "default_plan_mode") == null);
}

test "prompt mode stays quiet about plan mode when default_plan_mode is off" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    _ = try runWithDeps(
        alloc,
        &.{ "--json", "hello" },
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testMissingKeyStartup),
    );

    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "default_plan_mode") == null);
}

test "headless yolo warning precedes startup configuration diagnostics" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    TestYoloPersistence.reset();
    defer TestYoloPersistence.reset();

    var deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testMissingKeyDiagnosticStartup,
    );
    deps.persist_yolo_acknowledgment = TestYoloPersistence.persist;
    _ = try runWithDeps(
        alloc,
        &.{ "--yolo", "hello" },
        testConfig(),
        deps,
    );

    try std.testing.expect(std.mem.startsWith(
        u8,
        stderr_capture.bytes.items,
        permissions.yolo_warning_text ++ "\n" ++
            "fx ask: config user: malformed_settings\n",
    ));
}

test "headless yolo persistence is skipped when warning emission fails" {
    TestYoloPersistence.reset();
    defer TestYoloPersistence.reset();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(std.testing.allocator);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(std.testing.allocator);
    var deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testMissingKeyStartup,
    );
    deps.stderr_ctx = null;
    deps.write_stderr = TestFailingStderr.write;
    deps.persist_yolo_acknowledgment = TestYoloPersistence.persist;

    try std.testing.expectError(
        error.TestStderrWriteFailed,
        emitHeadlessYoloWarning(std.testing.allocator, .{
            .output_mode = .raw,
            .deps = deps,
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), TestYoloPersistence.calls);
}

test "headless yolo warning respects acknowledgment and no-color" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    TestYoloPersistence.reset();
    defer TestYoloPersistence.reset();

    var acknowledged_deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testMissingKeyAcknowledgedStartup,
    );
    acknowledged_deps.persist_yolo_acknowledgment = TestYoloPersistence.persist;
    _ = try runWithDeps(
        alloc,
        &.{ "--yolo", "hello" },
        testConfig(),
        acknowledged_deps,
    );
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, permissions.yolo_warning_text) == null);
    try std.testing.expectEqual(@as(usize, 0), TestYoloPersistence.calls);

    stderr_capture.bytes.clearRetainingCapacity();
    var color_deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testMissingKeyStartup,
    );
    color_deps.stderr_is_tty = TestTty.yes;
    color_deps.persist_yolo_acknowledgment = TestYoloPersistence.persist;
    _ = try runWithDeps(
        alloc,
        &.{ "--yolo", "hello" },
        testConfig(),
        color_deps,
    );
    try std.testing.expect(std.mem.startsWith(
        u8,
        stderr_capture.bytes.items,
        "\x1b[38;5;252m" ++ permissions.yolo_warning_text ++ "\x1b[0m\n",
    ));

    stderr_capture.bytes.clearRetainingCapacity();
    var no_color_deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testMissingKeyStartup,
    );
    no_color_deps.stderr_is_tty = TestTty.yes;
    no_color_deps.persist_yolo_acknowledgment = TestYoloPersistence.persist;
    _ = try runWithDeps(
        alloc,
        &.{ "--no-color", "--yolo", "hello" },
        testConfig(),
        no_color_deps,
    );
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "\x1b[31m") == null);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, permissions.yolo_warning_text) != null);
}

test "runWithDeps reports a missing image before startup after cleaning prior attachments" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "valid.png", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\nrest");
    }
    const valid_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "valid.png");
    defer alloc.free(valid_path);
    const valid_path_z = try alloc.dupeSentinel(u8, valid_path, 0);
    defer alloc.free(valid_path_z);
    const missing_path_z = try alloc.dupeSentinel(u8, "/tmp/fx-ask-missing-image.png", 0);
    defer alloc.free(missing_path_z);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    test_image_preflight_startup_calls = 0;
    test_image_preflight_process_calls = 0;
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testCountImagePreflightStartup);
    deps.process_queued_prompt = testCountImagePreflightProcess;

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--image", valid_path_z, "--image", missing_path_z, "describe" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqual(@as(usize, 0), test_image_preflight_startup_calls);
    try std.testing.expectEqual(@as(usize, 0), test_image_preflight_process_calls);
    try std.testing.expectEqual(@as(usize, 0), stdout_capture.bytes.items.len);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, missing_path_z) != null);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "image file not found") != null);
}

test "runWithDeps reports unsupported images in JSON before startup" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "not-image.txt", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "plain text");
    }
    const invalid_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "not-image.txt");
    defer alloc.free(invalid_path);
    const invalid_path_z = try alloc.dupeSentinel(u8, invalid_path, 0);
    defer alloc.free(invalid_path_z);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    test_image_preflight_startup_calls = 0;
    test_image_preflight_process_calls = 0;
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testCountImagePreflightStartup);
    deps.process_queued_prompt = testCountImagePreflightProcess;

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "--image", invalid_path_z, "describe" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqual(@as(usize, 0), test_image_preflight_startup_calls);
    try std.testing.expectEqual(@as(usize, 0), test_image_preflight_process_calls);
    try std.testing.expectEqual(@as(usize, 0), stderr_capture.bytes.items.len);
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, "\"exit_code\":1") != null);
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, "UnsupportedImageType") != null);
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, invalid_path_z) != null);
}

test "runWithDeps assigns image ids and owns the authorized catalog before processing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "valid.png", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\nrest");
    }
    const image_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "valid.png");
    defer alloc.free(image_path);
    const image_path_z = try alloc.dupeSentinel(u8, image_path, 0);
    defer alloc.free(image_path_z);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.process_queued_prompt = testProcessQueuedPromptCapturesNoSaveSnapshot;
    test_no_save_snapshot_path = null;
    defer if (test_no_save_snapshot_path) |path| alloc.free(path);

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "--no-save", "--image", image_path_z, "describe" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_capture.bytes.items.len);
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, "assistant text") != null);
    const snapshot_path = test_no_save_snapshot_path orelse return error.TestExpectedEqual;
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.openFileAbsolute(std.testing.io, snapshot_path, .{}),
    );
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.openDirAbsolute(std.testing.io, std.Io.Dir.path.dirname(snapshot_path).?, .{}),
    );
}

test "preflightAskImages resolves image paths from the workspace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "target.png", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\nrest");
    }
    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace_root);
    const expected_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "target.png");
    defer alloc.free(expected_path);

    var options = AskOptions{ .prompt = try alloc.dupe(u8, "describe") };
    defer options.deinit(alloc);
    try options.image_paths.append(alloc, try alloc.dupe(u8, "target.png"));

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    const deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);

    try std.testing.expect(try preflightAskImages(alloc, workspace_root, &options, deps));
    try std.testing.expectEqual(@as(usize, 1), options.images.items.len);
    try std.testing.expectEqualStrings(expected_path, options.images.items[0].path);
}

test "parse options rejects unknown flags and bad timeouts and accepts dash prompts after sentinel" {
    var problem: AskUsageProblem = .none;
    try std.testing.expectError(
        error.InvalidAskArgs,
        parseAskOptions(std.testing.allocator, &.{ "--timeout", "5", "--not-a-flag", "prompt" }, .tty, &problem),
    );
    try std.testing.expectEqualStrings("--not-a-flag", problem.flag.unknown.flag);

    try std.testing.expectError(
        error.InvalidAskArgs,
        parseAskOptions(std.testing.allocator, &.{ "--timeout", "nope", "prompt" }, .tty, &problem),
    );
    try std.testing.expectEqualStrings("--timeout", problem.invalid_value.flag);

    var options = try parseOptionsWithStdin(std.testing.allocator, &.{ "--timeout=5", "--", "--not-a-flag", "prompt" }, .tty);
    defer options.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?usize, 5 * std.time.ms_per_s), options.timeout_ms);
    try std.testing.expectEqualStrings("--not-a-flag prompt", options.prompt);
}

test "parse options names a missing flag value and reports empty tty input as missing prompt" {
    for ([_][:0]const u8{ "--image", "--system", "--timeout" }) |flag| {
        var problem: AskUsageProblem = .none;
        try std.testing.expectError(error.InvalidAskArgs, parseAskOptions(std.testing.allocator, &.{flag}, .tty, &problem));
        try std.testing.expectEqualStrings(flag, problem.flag.missing_value);
    }
    try std.testing.expectError(error.MissingPrompt, parseOptionsWithStdin(std.testing.allocator, &.{}, .tty));
}

test "stdin prompt resource limit accepts exact bytes and rejects one over without a partial prompt" {
    const alloc = std.testing.allocator;
    var exact_reader = std.Io.Reader.fixed("12345678");
    const exact = try readPromptFromReader(alloc, &exact_reader, 8);
    defer alloc.free(exact);
    try std.testing.expectEqualStrings("12345678", exact);

    var over_reader = std.Io.Reader.fixed("123456789");
    try std.testing.expectError(
        error.PromptResourceLimitExceeded,
        readPromptFromReader(alloc, &over_reader, 8),
    );

    try std.testing.expectError(
        error.PromptResourceLimitExceeded,
        readPromptFromStdinSourceWithLimit(alloc, .{ .bytes = "123456789" }, 8),
    );
    try std.testing.expectError(
        error.PromptInputReadFailed,
        readPromptFromStdinSourceWithLimit(alloc, .read_error, 8),
    );
}

test "stdin prompt reader propagates allocation failure" {
    var failing = std.testing.FailingAllocator.init(
        testing_allocator.no_resize,
        .{ .fail_index = 0 },
    );
    var reader = std.Io.Reader.fixed("prompt");
    try std.testing.expectError(
        error.OutOfMemory,
        readPromptFromReader(failing.allocator(), &reader, 8),
    );
}

test "stdin prompt errors keep exact structured names" {
    const alloc = std.testing.allocator;
    const overflow = try renderErrorJsonResult(alloc, "PromptResourceLimitExceeded", 1);
    defer alloc.free(overflow);
    try std.testing.expectEqualStrings(
        "{\"output\":\"\",\"final_output\":\"\",\"exit_code\":1,\"model\":\"\",\"resolved_provider\":null,\"session_id\":\"\",\"steps\":0,\"tool_calls\":[],\"usage\":{\"input_tokens\":null,\"output_tokens\":null},\"error\":\"PromptResourceLimitExceeded\"}\n",
        overflow,
    );

    const read_failure = try renderErrorJsonResult(alloc, "PromptInputReadFailed", 1);
    defer alloc.free(read_failure);
    try std.testing.expectEqualStrings(
        "{\"output\":\"\",\"final_output\":\"\",\"exit_code\":1,\"model\":\"\",\"resolved_provider\":null,\"session_id\":\"\",\"steps\":0,\"tool_calls\":[],\"usage\":{\"input_tokens\":null,\"output_tokens\":null},\"error\":\"PromptInputReadFailed\"}\n",
        read_failure,
    );
}

test "image preparation failure has stable text and JSON contracts" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqualStrings(
        image_attachments.image_preparation_failed_notice,
        askErrorNotice(error.ImagePreparationFailed).?,
    );
    try std.testing.expect(askErrorNotice(error.Cancelled) == null);
    try std.testing.expect(askErrorNotice(error.TimedOut) == null);

    const json = try renderErrorJsonResult(alloc, @errorName(error.ImagePreparationFailed), 1);
    defer alloc.free(json);
    try std.testing.expectEqualStrings(
        "{\"output\":\"\",\"final_output\":\"\",\"exit_code\":1,\"model\":\"\",\"resolved_provider\":null,\"session_id\":\"\",\"steps\":0,\"tool_calls\":[],\"usage\":{\"input_tokens\":null,\"output_tokens\":null},\"error\":\"ImagePreparationFailed\"}\n",
        json,
    );
}

test "an mcp.json fx can't read gets words in text and keeps its name in JSON" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqualStrings(mcp_verbs.describe(error.McpConfigTooLarge), askErrorNotice(error.McpConfigTooLarge).?);
    try std.testing.expect(askErrorNotice(error.StreamTooLong) == null);

    const json = try renderErrorJsonResult(alloc, @errorName(error.McpConfigTooLarge), 1);
    defer alloc.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"error\":\"McpConfigTooLarge\"") != null);
}

test "unresolved image capability has actionable text and stable JSON code" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqualStrings(
        "Unable to verify image support for this model, so the image was not sent. Try again later, choose another model, or remove the image.",
        askErrorNotice(error.ModelImageCapabilityUnavailable).?,
    );

    const json = try renderErrorJsonResult(
        alloc,
        @errorName(error.ModelImageCapabilityUnavailable),
        1,
    );
    defer alloc.free(json);
    try std.testing.expectEqualStrings(
        "{\"output\":\"\",\"final_output\":\"\",\"exit_code\":1,\"model\":\"\",\"resolved_provider\":null,\"session_id\":\"\",\"steps\":0,\"tool_calls\":[],\"usage\":{\"input_tokens\":null,\"output_tokens\":null},\"error\":\"ModelImageCapabilityUnavailable\"}\n",
        json,
    );
}

test "stdin read failure has distinct text and JSON output contracts" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.stdin_source = .read_error;

    try std.testing.expectEqual(
        @as(u8, 1),
        try runWithDeps(alloc, &.{}, testConfig(), deps),
    );
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
    try std.testing.expectEqualStrings(
        "fx ask: failed to read prompt from stdin\n",
        stderr_capture.bytes.items,
    );

    stdout_capture.bytes.clearRetainingCapacity();
    stderr_capture.bytes.clearRetainingCapacity();
    try std.testing.expectEqual(
        @as(u8, 1),
        try runWithDeps(alloc, &.{"--json"}, testConfig(), deps),
    );
    try std.testing.expectEqualStrings(
        "{\"output\":\"\",\"final_output\":\"\",\"exit_code\":1,\"model\":\"\",\"resolved_provider\":null,\"session_id\":\"\",\"steps\":0,\"tool_calls\":[],\"usage\":{\"input_tokens\":null,\"output_tokens\":null},\"error\":\"PromptInputReadFailed\"}\n",
        stdout_capture.bytes.items,
    );
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
}

test "runWithDeps threads timeout into ask tool context" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--timeout", "1", "hello" },
        testConfig(),
        testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, testProcessQueuedPromptChecksTimeout),
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("assistant text", stdout_capture.bytes.items);
}

test "cli ask admits default-safe web_search without a rule" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), "/tmp/workspace");
    defer ctx.deinit();
    const call = ToolCall{
        .id = "search",
        .name = "WebSearch",
        .arguments_json = "{\"query\":\"current news\"}",
    };

    try std.testing.expectEqual(ToolPermissionDecision.once, (try requestToolPermissionOutcome(&ctx, arena, call, .auto, &.{}, &.{})).decision);

    ctx.permission_rules = try testPermissionRuleSet(alloc, "WebSearch", "*", .allow);
    try std.testing.expectEqual(ToolPermissionDecision.once, (try requestToolPermissionOutcome(&ctx, arena, call, .auto, &.{}, &.{})).decision);
}

test "fx ask default user commands require configured authority or review" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), "/tmp/workspace");
    defer ctx.deinit();

    try expectNoninteractiveDenial(try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "direct",
        .name = "Bash",
        .arguments_json = "{\"command\":\"pwd\"}",
    }, .ask, &.{}, &.{}));

    try expectNoninteractiveDenial(try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "blocked",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch blocked.txt\"}",
    }, .ask, &.{}, &.{}));

    ctx.permission_rules = try testPermissionRuleSet(alloc, "bash", "touch *", .allow);
    const configured = (try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "configured",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch configured.txt\"}",
    }, .ask, &.{}, &.{}));
    switch ((configured.execution_authority orelse return error.TestExpectedEqual).run_command) {
        .direct_only => return error.TestExpectedShellAllowed,
        .shell_allowed => |authority| try std.testing.expectEqual(command_admission.ShellAuthorizationSource.configured_rule, authority.source),
    }

    ctx.permission_rules.deinit(alloc);
    ctx.permission_rules = .{};
    const automatic = try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "automatic",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch automatic.txt\"}",
    }, .auto, &.{}, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, automatic.decision);
    try std.testing.expect(automatic.denial_reason == null);
    switch ((automatic.execution_authority orelse return error.TestExpectedEqual).run_command) {
        .direct_only => return error.TestExpectedShellAllowed,
        .shell_allowed => |authority| try std.testing.expectEqual(command_admission.ShellAuthorizationSource.auto_mode, authority.source),
    }
}

test "fx ask auto approves a cancelled worker's command without a reviewer" {
    const Provider = struct {
        var calls: usize = 0;
        fn review(
            _: ?*anyopaque,
            _: Allocator,
            _: permission_auto_classifier.ProviderInput,
            _: permission_auto_classifier.ReviewRequest,
        ) anyerror!permission_auto_classifier.ParseOutcome {
            calls += 1;
            return .{ .invalid = .provider_failed };
        }
    };

    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var cfg = testConfig();
    cfg.provider_set.gateway.permission_reviewer = .{ .review_fn = Provider.review };
    var ctx = AskContext.init(
        alloc,
        cfg,
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer ctx.deinit();
    ctx.worker.worker_cancel_requested.store(true, .seq_cst);

    const call: ToolCall = .{
        .id = "cancelled-review",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch cancelled.txt\"}",
    };
    var review_turn = TestReviewTurn.init("Create cancelled.txt.", call);
    const outcome = try requestToolPermissionOutcomeWithRequest(&ctx, arena_state.allocator(), call, review_turn.context(), .auto, &.{}, null, null, &.{}, null);
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    try std.testing.expectEqual(@as(usize, 0), Provider.calls);
}

test "headless ask SIGHUP sets cancellation and exits 129" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    var scope = try headless_interrupt.Scope.install(true);
    defer scope.deinit();

    _ = std.c.raise(std.posix.SIG.HUP);

    try std.testing.expect(headless_interrupt.cancel_requested.load(.seq_cst));
    try std.testing.expectEqual(@as(u8, 129), headless_interrupt.exitCode());
}

test "headless ask SIGINT sets process-lifetime cancellation storage" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    var scope = try headless_interrupt.Scope.install(true);
    defer scope.deinit();

    _ = std.c.raise(std.posix.SIG.INT);

    try std.testing.expect(headless_interrupt.cancel_requested.load(.seq_cst));
}

test "headless ask interrupt installation exposes a typed busy result" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    const InstallResult = @TypeOf(headless_interrupt.Scope.install(true));
    try std.testing.expect(
        std.meta.activeTag(@typeInfo(InstallResult)) == .error_union,
    );
}

var test_previous_sigint_count = std.atomic.Value(usize).init(0);
fn testPreviousSigintHandler(_: std.posix.SIG) callconv(.c) void {
    _ = test_previous_sigint_count.fetchAdd(1, .seq_cst);
}

fn testProcessQueuedPromptRaisesSigintAndSucceeds(
    agent: *agent_runtime.Agent,
    deps: *const agent_runtime.AgentRuntimeDeps,
    semantic_presentation: ?agent_runtime.SemanticPresentationSink,
    lifecycle: agent_runtime.LifecycleContext,
    cfg: agent_runtime.Config,
    job: worker_runtime.QueuedPrompt,
) !void {
    if (comptime supports_headless_interrupt) {
        _ = std.c.raise(std.posix.SIG.INT);
    }
    try testProcessQueuedPrompt(
        agent,
        deps,
        semantic_presentation,
        lifecycle,
        cfg,
        job,
    );
}

const StartupCancellationStage = enum {
    after_startup_state,
    during_session_initialization,
    during_context_gather,
    during_mcp_load,
};

var test_startup_cancellation_stage: StartupCancellationStage = .after_startup_state;
var test_startup_cancellation_session_calls: usize = 0;
var test_startup_cancellation_context_calls: usize = 0;
var test_startup_cancellation_mcp_calls: usize = 0;
var test_startup_cancellation_process_calls: usize = 0;

fn requestTestHeadlessInterrupt() void {
    if (comptime supports_headless_interrupt) {
        headless_interrupt.handle(std.posix.SIG.INT);
    }
}

fn testLoadStartupStateWithCancellation(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
    _: ?model_provider.ProviderId,
    _: ?[]const u8,
    _: []const config_runtime.SettingOverride,
) !app_lifecycle.StartupState {
    const state = try testPresentKeyStartup(
        alloc,
        transport,
        secret_store,
        default_model,
        default_agent_step_limit,
        null,
        null,
        &.{},
    );
    if (test_startup_cancellation_stage == .after_startup_state) {
        requestTestHeadlessInterrupt();
    }
    return state;
}

fn testInitializeSessionStoresWithCancellation(_: *AskContext) !void {
    test_startup_cancellation_session_calls += 1;
    if (test_startup_cancellation_stage == .during_session_initialization) {
        requestTestHeadlessInterrupt();
    }
}

fn testGatherContextWithCancellation(
    _: Allocator,
    _: context_contract.InitialContextInput,
) context_contract.ProviderError!context_contract.ProviderContext {
    test_startup_cancellation_context_calls += 1;
    if (test_startup_cancellation_stage == .during_context_gather) {
        requestTestHeadlessInterrupt();
    }
    return .{};
}

const test_startup_cancellation_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.startup_cancellation",
    .gather_project_context_fn = testGatherContextWithCancellation,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = testNoStaticContext,
    .append_transient_fn = testNoTransientContext,
} };

fn testLoadMcpHostWithCancellation(_: Allocator, _: []const u8, _: tool_dispatch.Registry, _: mcp_host.Extras) anyerror!?*mcp_host.Host {
    test_startup_cancellation_mcp_calls += 1;
    if (test_startup_cancellation_stage == .during_mcp_load) {
        requestTestHeadlessInterrupt();
    }
    return null;
}

fn testProcessQueuedPromptAfterStartupCancellation(
    agent: *agent_runtime.Agent,
    deps: *const agent_runtime.AgentRuntimeDeps,
    semantic_presentation: ?agent_runtime.SemanticPresentationSink,
    lifecycle: agent_runtime.LifecycleContext,
    cfg: agent_runtime.Config,
    job: worker_runtime.QueuedPrompt,
) !void {
    test_startup_cancellation_process_calls += 1;
    try testProcessQueuedPrompt(
        agent,
        deps,
        semantic_presentation,
        lifecycle,
        cfg,
        job,
    );
}

fn testRaiseSigintAtInstallBoundary() void {
    _ = std.c.raise(std.posix.SIG.INT);
}

fn testRaiseSigintAtTeardownBoundary() void {
    headless_interrupt.cancel_requested.store(false, .seq_cst);
    _ = std.c.raise(std.posix.SIG.INT);
}

const CrossThreadSigintState = struct {
    request: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sent: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn sendRequestedSigints(state: *CrossThreadSigintState) void {
    if (comptime !supports_headless_interrupt) return;
    while (!state.stop.load(.seq_cst)) {
        if (!state.request.swap(false, .seq_cst)) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
            continue;
        }
        std.posix.kill(std.c.getpid(), std.posix.SIG.INT) catch {
            state.failed.store(true, .seq_cst);
        };
        state.sent.store(true, .seq_cst);
    }
}

test "headless ask rejects concurrent and nested interrupt scopes without overwrite" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    var first = try headless_interrupt.Scope.install(true);
    defer first.deinit();

    try std.testing.expectError(
        error.HeadlessInterruptBusy,
        headless_interrupt.Scope.install(true),
    );

    const ConcurrentAttempt = struct {
        fn run(result: *std.atomic.Value(u8)) void {
            var scope = headless_interrupt.Scope.install(true) catch |err| {
                result.store(
                    if (err == error.HeadlessInterruptBusy) 1 else 2,
                    .seq_cst,
                );
                return;
            };
            defer scope.deinit();
            result.store(3, .seq_cst);
        }
    };
    var result = std.atomic.Value(u8).init(0);
    const thread = try std.Thread.spawn(.{}, ConcurrentAttempt.run, .{&result});
    thread.join();
    try std.testing.expectEqual(@as(u8, 1), result.load(.seq_cst));

    _ = std.c.raise(std.posix.SIG.INT);
    try std.testing.expect(headless_interrupt.cancel_requested.load(.seq_cst));
}

test "headless ask restores the exact previous SIGINT handler" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    const previous_action: std.posix.Sigaction = .{
        .handler = .{ .handler = testPreviousSigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var original_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &previous_action, &original_action);
    defer std.posix.sigaction(std.posix.SIG.INT, &original_action, null);
    test_previous_sigint_count.store(0, .seq_cst);

    var scope = try headless_interrupt.Scope.install(true);
    _ = std.c.raise(std.posix.SIG.INT);
    try std.testing.expect(headless_interrupt.cancel_requested.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), test_previous_sigint_count.load(.seq_cst));
    scope.deinit();

    _ = std.c.raise(std.posix.SIG.INT);
    try std.testing.expectEqual(@as(usize, 1), test_previous_sigint_count.load(.seq_cst));
}

test "headless ask redelivers consumed SIGINT after restoring the previous handler" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    const previous_action: std.posix.Sigaction = .{
        .handler = .{ .handler = testPreviousSigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var original_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &previous_action, &original_action);
    defer std.posix.sigaction(std.posix.SIG.INT, &original_action, null);
    test_previous_sigint_count.store(0, .seq_cst);

    var scope = try headless_interrupt.Scope.install(true);
    defer scope.deinit();
    _ = std.c.raise(std.posix.SIG.INT);
    try std.testing.expect(headless_interrupt.cancel_requested.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), test_previous_sigint_count.load(.seq_cst));

    scope.restoreAndRedeliver();

    try std.testing.expectEqual(@as(usize, 1), test_previous_sigint_count.load(.seq_cst));
}

test "headless ask returns nonzero when the restored SIGINT handler returns" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    const previous_action: std.posix.Sigaction = .{
        .handler = .{ .handler = testPreviousSigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var original_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &previous_action, &original_action);
    defer std.posix.sigaction(std.posix.SIG.INT, &original_action, null);
    test_previous_sigint_count.store(0, .seq_cst);

    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDepsWithProcess(
        &stdout_capture,
        &stderr_capture,
        testProcessQueuedPromptRaisesSigintAndSucceeds,
    );
    deps.install_headless_interrupt = true;

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "hello" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 130), exit_code);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), test_previous_sigint_count.load(.seq_cst));
}

test "headless ask startup cancellation prevents later hooks" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    const previous_action: std.posix.Sigaction = .{
        .handler = .{ .handler = testPreviousSigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var original_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &previous_action, &original_action);
    defer std.posix.sigaction(std.posix.SIG.INT, &original_action, null);

    const cases = [_]struct {
        stage: StartupCancellationStage,
        session_calls: usize,
        context_calls: usize,
        mcp_calls: usize,
    }{
        .{ .stage = .after_startup_state, .session_calls = 0, .context_calls = 0, .mcp_calls = 0 },
        .{ .stage = .during_session_initialization, .session_calls = 1, .context_calls = 0, .mcp_calls = 0 },
        .{ .stage = .during_context_gather, .session_calls = 1, .context_calls = 1, .mcp_calls = 0 },
        .{ .stage = .during_mcp_load, .session_calls = 1, .context_calls = 1, .mcp_calls = 1 },
    };

    for (cases) |case| {
        test_startup_cancellation_stage = case.stage;
        test_startup_cancellation_session_calls = 0;
        test_startup_cancellation_context_calls = 0;
        test_startup_cancellation_mcp_calls = 0;
        test_startup_cancellation_process_calls = 0;
        test_previous_sigint_count.store(0, .seq_cst);

        const alloc = std.testing.allocator;
        var stdout_capture: TestCapture = .{};
        defer stdout_capture.deinit(alloc);
        var stderr_capture: TestCapture = .{};
        defer stderr_capture.deinit(alloc);
        var deps = testPromptRunDepsWithProcess(
            &stdout_capture,
            &stderr_capture,
            testProcessQueuedPromptAfterStartupCancellation,
        );
        deps.load_startup_state = testLoadStartupStateWithCancellation;
        deps.initialize_session_stores = testInitializeSessionStoresWithCancellation;
        deps.context_registry = test_startup_cancellation_context_registry;
        deps.load_mcp_host = testLoadMcpHostWithCancellation;
        deps.install_headless_interrupt = true;

        const exit_code = try runWithDeps(alloc, &.{"hello"}, testConfig(), deps);

        try std.testing.expectEqual(@as(u8, 130), exit_code);
        try std.testing.expectEqual(case.session_calls, test_startup_cancellation_session_calls);
        try std.testing.expectEqual(case.context_calls, test_startup_cancellation_context_calls);
        try std.testing.expectEqual(case.mcp_calls, test_startup_cancellation_mcp_calls);
        try std.testing.expectEqual(@as(usize, 0), test_startup_cancellation_process_calls);
        try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
        try std.testing.expectEqual(@as(usize, 1), test_previous_sigint_count.load(.seq_cst));
    }
}

test "headless ask resets signal-visible cancellation state for each scope" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    var scope = try headless_interrupt.Scope.install(true);
    headless_interrupt.handle(std.posix.SIG.INT);
    try std.testing.expect(headless_interrupt.cancel_requested.load(.seq_cst));
    scope.deinit();

    headless_interrupt.handle(std.posix.SIG.INT);
    try std.testing.expect(headless_interrupt.cancel_requested.load(.seq_cst));

    var next = try headless_interrupt.Scope.install(true);
    defer next.deinit();
    try std.testing.expect(!headless_interrupt.cancel_requested.load(.seq_cst));
}

test "headless ask preserves signal ordering during install and teardown" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    const previous_action: std.posix.Sigaction = .{
        .handler = .{ .handler = testPreviousSigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var original_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &previous_action, &original_action);
    defer std.posix.sigaction(std.posix.SIG.INT, &original_action, null);
    test_previous_sigint_count.store(0, .seq_cst);

    headless_interrupt.test_after_reset_before_install = testRaiseSigintAtInstallBoundary;
    defer headless_interrupt.test_after_reset_before_install = null;
    var scope = try headless_interrupt.Scope.install(true);
    try std.testing.expect(!headless_interrupt.cancel_requested.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), test_previous_sigint_count.load(.seq_cst));

    headless_interrupt.test_after_reset_before_install = null;
    headless_interrupt.test_after_restore = testRaiseSigintAtTeardownBoundary;
    defer headless_interrupt.test_after_restore = null;
    scope.deinit();

    try std.testing.expect(!headless_interrupt.cancel_requested.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), test_previous_sigint_count.load(.seq_cst));
}

test "headless ask cross-thread SIGINT teardown and reuse target only the active scope" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    const previous_action: std.posix.Sigaction = .{
        .handler = .{ .handler = testPreviousSigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var original_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &previous_action, &original_action);
    defer std.posix.sigaction(std.posix.SIG.INT, &original_action, null);

    var state = CrossThreadSigintState{};
    const sender = try std.Thread.spawn(.{}, sendRequestedSigints, .{&state});
    defer {
        state.stop.store(true, .seq_cst);
        sender.join();
    }

    for (0..128) |_| {
        var first = try headless_interrupt.Scope.install(true);
        state.sent.store(false, .seq_cst);
        state.request.store(true, .seq_cst);
        while (!state.sent.load(.seq_cst)) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        first.deinit();

        var next = try headless_interrupt.Scope.install(true);
        for (0..4) |_| {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        try std.testing.expect(!headless_interrupt.cancel_requested.load(.seq_cst));
        _ = std.c.raise(std.posix.SIG.INT);
        try std.testing.expect(headless_interrupt.cancel_requested.load(.seq_cst));
        next.deinit();
    }
    try std.testing.expect(!state.failed.load(.seq_cst));
}

test "disabled headless ask scope leaves the interactive SIGINT handler untouched" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    const previous_action: std.posix.Sigaction = .{
        .handler = .{ .handler = testPreviousSigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var original_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &previous_action, &original_action);
    defer std.posix.sigaction(std.posix.SIG.INT, &original_action, null);
    test_previous_sigint_count.store(0, .seq_cst);

    headless_interrupt.cancel_requested.store(false, .seq_cst);
    var scope = try headless_interrupt.Scope.install(false);
    defer scope.deinit();
    _ = std.c.raise(std.posix.SIG.INT);

    try std.testing.expect(!headless_interrupt.cancel_requested.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), test_previous_sigint_count.load(.seq_cst));
}

test "fx ask auto mode approves without a classifier or a prompt" {
    const FakeClassifier = struct {
        calls: usize = 0,
        decision: permission_auto_classifier.Decision = .clear,

        fn classify(
            raw_ctx: *anyopaque,
            alloc: Allocator,
            _: permission_auto_classifier.ReviewRequest,
        ) anyerror!permission_auto_classifier.ParseOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx));
            self.calls += 1;
            return .{ .valid = .{
                .risk = if (self.decision == .clear) .low else .high,
                .decision = self.decision,
                .rationale = try alloc.dupe(u8, "test automatic review"),
            } };
        }
    };

    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), "/tmp/workspace");
    defer ctx.deinit();
    var fake = FakeClassifier{ .decision = .clear };
    ctx.auto_classifier = permission_auto_classifier.Classifier.withOverride(
        @ptrCast(&fake),
        FakeClassifier.classify,
    );

    const direct_call: ToolCall = .{
        .id = "direct",
        .name = "Bash",
        .arguments_json = "{\"command\":\"pwd\"}",
    };
    var direct_review = TestReviewTurn.init("Inspect the workspace.", direct_call);
    const direct = try requestToolPermissionOutcomeWithRequest(&ctx, arena, direct_call, direct_review.context(), .auto, &.{}, null, null, &.{}, null);
    try std.testing.expectEqual(ToolPermissionDecision.once, direct.decision);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.auto_mode,
        direct.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);

    const accepted_call: ToolCall = .{
        .id = "accepted",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch accepted.txt\"}",
    };
    var accepted_review = TestReviewTurn.init("Create accepted.txt.", accepted_call);
    const accepted = try requestToolPermissionOutcomeWithRequest(&ctx, arena, accepted_call, accepted_review.context(), .auto, &.{}, null, null, &.{}, null);
    try std.testing.expectEqual(ToolPermissionDecision.once, accepted.decision);
    switch ((accepted.execution_authority orelse return error.TestExpectedEqual).run_command) {
        .direct_only => return error.TestExpectedShellAllowed,
        .shell_allowed => |authority| try std.testing.expectEqual(
            command_admission.ShellAuthorizationSource.auto_mode,
            authority.source,
        ),
    }
    try std.testing.expectEqual(@as(usize, 0), fake.calls);

    fake.decision = .caution;
    const check_call: ToolCall = .{
        .id = "check",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch check.txt\"}",
    };
    var check_review = TestReviewTurn.init("Check this command.", check_call);
    const blocked = try requestToolPermissionOutcomeWithRequest(&ctx, arena, check_call, check_review.context(), .auto, &.{}, null, null, &.{}, null);
    try std.testing.expectEqual(ToolPermissionDecision.once, blocked.decision);
    try std.testing.expect(blocked.denial_reason == null);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
}

test "fx ask terminal permission prompt approves and denies run_command" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var prompt = TestPermissionPrompt{ .result = .approve };
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.permission_approval_prompt_ctx = @ptrCast(&prompt);
    deps.permission_approval_prompt = TestPermissionPrompt.prompt;
    var ctx = AskContext.init(alloc, testConfig(), deps, "/tmp/workspace");
    defer ctx.deinit();

    const approved = (try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "approved",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch approved.txt\"}",
    }, .ask, &.{}, &.{}));
    switch ((approved.execution_authority orelse return error.TestExpectedEqual).run_command) {
        .direct_only => return error.TestExpectedShellAllowed,
        .shell_allowed => |authority| try std.testing.expectEqual(
            command_admission.ShellAuthorizationSource.interactive_once,
            authority.source,
        ),
    }
    try std.testing.expectEqual(@as(usize, 1), prompt.calls);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "Approve? [y/N]") != null);
    try std.testing.expect(prompt.label != null);

    stdout_capture.bytes.clearRetainingCapacity();
    stderr_capture.bytes.clearRetainingCapacity();
    prompt.result = .deny;

    const denied = try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "denied",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch denied.txt\"}",
    }, .ask, &.{}, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.deny, denied.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.user_denied, denied.denial_reason.?);
    try std.testing.expect(denied.execution_authority == null);
    try std.testing.expectEqual(@as(usize, 2), prompt.calls);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "Approve? [y/N]") != null);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
}

test "fx ask permission attention fires once after a prompt is published" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var prompt = TestPermissionPrompt{ .result = .approve };
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.permission_approval_prompt_ctx = @ptrCast(&prompt);
    deps.permission_approval_prompt = TestPermissionPrompt.prompt;
    var ctx = AskContext.init(alloc, testConfig(), deps, "/tmp/workspace");
    defer ctx.deinit();
    ctx.active_turn_id = 42;
    var capture = AskAttentionCapture{};
    try ctx.lifecycle_runtime.registerAttentionRequired(.{
        .name = "capture",
        .ctx = &capture,
        .run = AskAttentionCapture.run,
    });
    ctx.lifecycle_view = ctx.lifecycle_runtime.freeze();

    _ = try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "attention",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch attention.txt\"}",
    }, .ask, &.{}, &.{});

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(u64, 42), capture.turn_id);
    try std.testing.expectEqual(@as(?hooks.AttentionKind, .permission), capture.kind);

    prompt.result = .unavailable;
    try expectNoninteractiveDenial(try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "unavailable",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch unavailable.txt\"}",
    }, .ask, &.{}, &.{}));
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "fx ask bell writes only to TTY stderr" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.stderr_is_tty = TestTty.yes;
    var ctx = AskContext.init(alloc, testConfig(), deps, "/tmp/workspace");
    defer ctx.deinit();

    emitAskNotificationBell(&ctx);
    try std.testing.expectEqualStrings("\x07", stderr_capture.bytes.items);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);

    stderr_capture.bytes.clearRetainingCapacity();
    ctx.deps.stderr_is_tty = TestTty.no;
    emitAskNotificationBell(&ctx);
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
}

test "fx ask registers sound handlers only when configured and always watches for a limit-ended turn" {
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(std.testing.allocator);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(std.testing.allocator);
    var disabled = AskContext.init(
        std.testing.allocator,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer disabled.deinit();
    try disabled.configureNotifications(false, false);
    try std.testing.expect(disabled.lifecycle_view.hasPostTurnEnd());
    try std.testing.expect(!disabled.lifecycle_view.hasAttentionRequired());

    var enabled = AskContext.init(
        std.testing.allocator,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer enabled.deinit();
    try enabled.configureNotifications(true, true);

    try std.testing.expect(enabled.lifecycle_view.hasPostTurnEnd());
    try std.testing.expect(enabled.lifecycle_view.hasAttentionRequired());
}

test "fx ask captured and quiet permission paths bypass terminal prompt" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var prompt = TestPermissionPrompt{ .result = .approve };
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.permission_approval_prompt_ctx = @ptrCast(&prompt);
    deps.permission_approval_prompt = TestPermissionPrompt.prompt;
    var ctx = AskContext.init(alloc, testConfig(), deps, "/tmp/workspace");
    defer ctx.deinit();

    ctx.output_mode = .json;
    try expectNoninteractiveDenial(try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "captured",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch captured.txt\"}",
    }, .ask, &.{}, &.{}));
    try std.testing.expectEqual(@as(usize, 0), prompt.calls);
    try std.testing.expectEqual(@as(usize, 0), ctx.tool_call_records.items.len);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "noninteractive_permission_prompt_unavailable") != null);

    stderr_capture.bytes.clearRetainingCapacity();
    ctx.output_mode = .quiet;
    try expectNoninteractiveDenial(try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "quiet",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch quiet.txt\"}",
    }, .ask, &.{}, &.{}));
    try std.testing.expectEqual(@as(usize, 0), prompt.calls);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "noninteractive_permission_prompt_unavailable") != null);
}

test "fx ask permission prompt policy requires explicit captured-mode opt in and TTY stdin" {
    const Case = struct {
        output_mode: OutputMode,
        prompt_permissions: bool,
        stdin_is_tty: bool,
        expected: bool,
    };
    const cases = [_]Case{
        .{ .output_mode = .raw, .prompt_permissions = false, .stdin_is_tty = false, .expected = true },
        .{ .output_mode = .terminal, .prompt_permissions = false, .stdin_is_tty = false, .expected = true },
        .{ .output_mode = .terminal_no_color, .prompt_permissions = false, .stdin_is_tty = false, .expected = true },
        .{ .output_mode = .json, .prompt_permissions = false, .stdin_is_tty = true, .expected = false },
        .{ .output_mode = .quiet, .prompt_permissions = false, .stdin_is_tty = true, .expected = false },
        .{ .output_mode = .json, .prompt_permissions = true, .stdin_is_tty = false, .expected = false },
        .{ .output_mode = .quiet, .prompt_permissions = true, .stdin_is_tty = false, .expected = false },
        .{ .output_mode = .json, .prompt_permissions = true, .stdin_is_tty = true, .expected = true },
        .{ .output_mode = .quiet, .prompt_permissions = true, .stdin_is_tty = true, .expected = true },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            cliPermissionPromptAllowed(
                case.output_mode,
                case.prompt_permissions,
                case.stdin_is_tty,
            ),
        );
    }
}

test "fx ask captured permission prompt opt in uses the existing prompter" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var prompt = TestPermissionPrompt{ .result = .approve };
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.permission_approval_prompt_ctx = @ptrCast(&prompt);
    deps.permission_approval_prompt = TestPermissionPrompt.prompt;
    deps.stdin_is_tty = TestTty.yes;
    var ctx = AskContext.init(alloc, testConfig(), deps, "/tmp/workspace");
    defer ctx.deinit();
    ctx.prompt_permissions = true;

    ctx.output_mode = .json;
    const approved = try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "captured-approved",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch captured-approved.txt\"}",
    }, .ask, &.{}, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, approved.decision);
    try std.testing.expectEqual(@as(usize, 1), prompt.calls);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "Approve? [y/N]") != null);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);

    prompt.result = .deny;
    ctx.output_mode = .quiet;
    const denied = try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "quiet-denied",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch quiet-denied.txt\"}",
    }, .ask, &.{}, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.deny, denied.decision);
    try std.testing.expectEqual(@as(usize, 2), prompt.calls);

    ctx.deps.stdin_is_tty = TestTty.no;
    try expectNoninteractiveDenial(try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "quiet-non-tty",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch quiet-non-tty.txt\"}",
    }, .ask, &.{}, &.{}));
    try std.testing.expectEqual(@as(usize, 2), prompt.calls);
}

test "fx ask terminal permission prompt propagates prompt hook errors" {
    const FailingPrompt = struct {
        fn prompt(
            _: ?*anyopaque,
            _: ?*anyopaque,
            _: WriteFn,
            _: []const u8,
            _: ?*anyopaque,
            _: NotifyAttentionFn,
        ) !PermissionApprovalPromptResult {
            return error.PromptFailure;
        }
    };

    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.permission_approval_prompt = FailingPrompt.prompt;
    var ctx = AskContext.init(alloc, testConfig(), deps, "/tmp/workspace");
    defer ctx.deinit();

    try std.testing.expectError(error.PromptFailure, requestToolPermissionOutcome(&ctx, arena, .{
        .id = "prompt-failure",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch prompt-failure.txt\"}",
    }, .ask, &.{}, &.{}));
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "noninteractive_permission_prompt_unavailable") == null);
}

test "fx ask prepared file mutation callback preserves terminal permission prompt" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var prompt = TestPermissionPrompt{ .result = .approve };
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.permission_approval_prompt_ctx = @ptrCast(&prompt);
    deps.permission_approval_prompt = TestPermissionPrompt.prompt;
    var ctx = AskContext.init(alloc, testConfig(), deps, workspace);
    defer ctx.deinit();

    const target_path = try std.Io.Dir.path.join(arena, &.{ external, "desktop-test.txt" });
    const call: ToolCall = .{
        .id = "external-write",
        .name = "write_file",
        .arguments_json = try arena.print(
            "{{\"path\":\"{s}\",\"content\":\"hello\\n\"}}",
            .{target_path},
        ),
    };
    var prepared = switch (try tool_admission.prepareFileMutationCall(arena, call, .{
        .tool_registry = ctx.toolRegistry(),
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .not_file_mutation => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer prepared.deinit(arena);
    const runtime_deps = agentRuntimeDeps(&ctx);
    const callback = runtime_deps.request_prepared_file_mutation_permission orelse
        return error.TestExpectedPreparedFileMutationCallback;
    var review_turn = TestReviewTurn.init("Approve this prepared mutation.", call);
    const accepted = try callback(
        runtime_deps.ctx,
        arena,
        call,
        &prepared,
        review_turn.context(),
        .ask,
        &.{},
        null,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 1), prompt.calls);
    try std.testing.expectEqual(ToolPermissionDecision.once, accepted.decision);
    const authorization = switch (accepted.execution_authority orelse return error.TestExpectedEqual) {
        .file_mutation => |authorization| authorization,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expectEqualStrings(target_path, authorization.input.path());
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "Approve? [y/N]") != null);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
}

test "fx ask auto mode uses automatic allow for external prepared file mutation" {
    const FakeClassifier = struct {
        calls: usize = 0,
        root_text: []const u8 = "",

        fn classify(
            raw_ctx: *anyopaque,
            alloc: Allocator,
            request: permission_auto_classifier.ReviewRequest,
        ) anyerror!permission_auto_classifier.ParseOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx));
            self.calls += 1;
            self.root_text = request.review_turn.trusted_root_context;
            try std.testing.expect(request.targets.len >= 1);
            const file = switch (request.action) {
                .file_mutation => |value| value,
                else => return error.TestExpectedEqual,
            };
            try std.testing.expectEqualStrings("write_file", file.tool_name);
            return .{ .valid = .{
                .risk = .medium,
                .decision = .clear,
                .rationale = try alloc.dupe(u8, "test automatic review"),
            } };
        }
    };

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), workspace);
    defer ctx.deinit();
    var fake = FakeClassifier{};
    ctx.auto_classifier = permission_auto_classifier.Classifier.withOverride(
        @ptrCast(&fake),
        FakeClassifier.classify,
    );

    const target_path = try std.Io.Dir.path.join(arena, &.{ external, "desktop-test.txt" });
    const arguments_json = try arena.print(
        "{{\"path\":\"{s}\",\"content\":\"hello\\n\"}}",
        .{target_path},
    );
    const call: ToolCall = .{
        .id = "external-write",
        .name = "write_file",
        .arguments_json = arguments_json,
    };
    var review_turn = TestReviewTurn.init("Write hello to desktop-test.txt.", call);
    const accepted = try requestToolPermissionOutcomeWithRequest(&ctx, arena, call, review_turn.context(), .auto, &.{}, null, null, &.{}, null);

    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqualStrings("", fake.root_text);
    try std.testing.expectEqual(ToolPermissionDecision.once, accepted.decision);
    const authorization = switch (accepted.execution_authority orelse return error.TestExpectedEqual) {
        .file_mutation => |authorization| authorization,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expectEqualStrings(target_path, authorization.input.path());
}

test "a non-interactive approval-required call is denied to the model with the Kimi text instead of ending the run" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), "/tmp/workspace");
    defer ctx.deinit();

    const call = ToolCall{
        .id = "needs-approval",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch needs-approval.txt\"}",
    };
    const outcome = try requestToolPermissionOutcome(&ctx, arena, call, .ask, &.{}, &.{});
    try expectNoninteractiveDenial(outcome);
    try std.testing.expect(outcome.decision.isDenied());
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "fx ask: blocked action: ") != null);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);

    const model_output = try tool_result_errors.toolPermissionDeniedJson(arena, call.name, outcome.denial_reason.?);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, model_output, .{});
    defer parsed.deinit();
    const denial = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings(
        "Tool \"Bash\" needs approval, but nobody can approve it in a non-interactive run.",
        denial.get("message").?.string,
    );
    try std.testing.expectEqualStrings("permission_required", denial.get("reason").?.string);
    try std.testing.expect(denial.get("denied").?.bool);
}

test "fx ask preserves CLI headless blocker diagnostics" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        workspace,
    );
    defer ctx.deinit();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    ctx.permission_rules = try testPermissionRuleSet(alloc, "bash", "touch configured.txt", .ask);
    const configured_rule_ask = ToolCall{
        .id = "configured-rule-ask",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch configured.txt\"}",
    };
    const configured_label = try tool_presentation.formatPlainAction(arena, .{ .tool_registry = ctx.toolRegistry(), .call = configured_rule_ask });
    try expectNoninteractiveDenial(try requestToolPermissionOutcome(
        &ctx,
        arena,
        configured_rule_ask,
        .ask,
        &.{},
        &.{},
    ));
    const expected_configured_stderr = try arena.print(
        "fx ask: permission required by configured rule\n" ++
            "fx ask: blocked action: {s}\n" ++
            "fx ask: reason=noninteractive_permission_prompt_unavailable\n" ++
            "fx ask: rerun in the interactive shell to approve this action, or add a narrow matching permission rule before retrying\n",
        .{configured_label},
    );
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
    try std.testing.expectEqualStrings(expected_configured_stderr, stderr_capture.bytes.items);

    ctx.permission_rules.deinit(alloc);
    ctx.permission_rules = .{};
    stdout_capture.bytes.clearRetainingCapacity();
    stderr_capture.bytes.clearRetainingCapacity();

    const approval_required = ToolCall{
        .id = "approval-required",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch approval.txt\"}",
    };
    const approval_label = try tool_presentation.formatPlainAction(arena, .{ .tool_registry = ctx.toolRegistry(), .call = approval_required });
    try expectNoninteractiveDenial(try requestToolPermissionOutcome(
        &ctx,
        arena,
        approval_required,
        .ask,
        &.{},
        &.{},
    ));
    const expected_approval_stderr = try arena.print(
        "fx ask: permission required for tool execution in noninteractive mode\n" ++
            "fx ask: blocked action: {s}\n" ++
            "fx ask: reason=noninteractive_permission_prompt_unavailable\n" ++
            "fx ask: rerun with --auto to run this action without asking, or use the interactive shell to approve it\n",
        .{approval_label},
    );
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
    try std.testing.expectEqualStrings(expected_approval_stderr, stderr_capture.bytes.items);

    stdout_capture.bytes.clearRetainingCapacity();
    stderr_capture.bytes.clearRetainingCapacity();

    const auto_approval = try requestToolPermissionOutcome(
        &ctx,
        arena,
        approval_required,
        .auto,
        &.{},
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, auto_approval.decision);
    try std.testing.expect(auto_approval.denial_reason == null);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);

    stdout_capture.bytes.clearRetainingCapacity();
    stderr_capture.bytes.clearRetainingCapacity();

    const default_safe_web_search = try requestToolPermissionOutcome(
        &ctx,
        arena,
        .{
            .id = "web-search-default",
            .name = "WebSearch",
            .arguments_json = "{\"query\":\"current news\"}",
        },
        .auto,
        &.{},
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, default_safe_web_search.decision);
    try std.testing.expect(default_safe_web_search.execution_authority != null);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
}

test "runWithDeps projects exec-only terminal when saved setup has no capability" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    const exit_code = try runWithDeps(
        alloc,
        &.{"hello"},
        testConfig(),
        testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, testProcessQueuedPromptChecksExecOnlyTerminal),
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("assistant text", stdout_capture.bytes.items);
}

test "runWithDeps uses the supplied tool set for advertisement and runtime" {
    const alloc = std.testing.allocator;
    const tools = [_]tool_dispatch.Tool{builtin_tools.read_file};
    const names = [_][]const u8{"read_file"};
    const tool_set: tool_set_contract.ToolSet = .{
        .registry = .{ .tools = tools[0..] },
        .order = names[0..],
        .read_only_tool_names = names[0..],
    };
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDepsWithProcess(
        &stdout_capture,
        &stderr_capture,
        testProcessQueuedPromptChecksInjectedToolSet,
    );
    deps.tool_set = tool_set;

    const exit_code = try runWithDeps(alloc, &.{"hello"}, testConfig(), deps);

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("assistant text", stdout_capture.bytes.items);
}

test "final ask json keeps shell tool call shape and adds command result" {
    const alloc = std.testing.allocator;
    const records = try alloc.alloc(ToolCallRecord, 1);
    records[0] = .{
        .name = try alloc.dupe(u8, "Bash"),
        .status = try alloc.dupe(u8, "success"),
        .command_result_json = try alloc.dupe(u8, "{\"kind\":\"command\",\"command\":\"printf ok\",\"cwd\":\"/tmp\",\"exit_code\":0,\"signal\":null,\"timed_out\":false,\"stdout_bytes\":2,\"stderr_bytes\":0,\"truncated\":false}"),
    };
    const result = PromptRunResult{
        .exit_code = 0,
        .assistant_output = try alloc.dupe(u8, "ok"),
        .model = try alloc.dupe(u8, "test-model"),
        .session_id = try alloc.dupe(u8, "session-1"),
        .tool_calls = records,
        .step_count = 1,
    };
    defer result.deinit(alloc);

    const rendered = try renderFinalJsonResult(alloc, result);
    defer alloc.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, rendered, .{});
    defer parsed.deinit();
    const tool_call = parsed.value.object.get("tool_calls").?.array.items[0].object;
    try std.testing.expectEqualStrings("Bash", tool_call.get("name").?.string);
    try std.testing.expectEqualStrings("success", tool_call.get("status").?.string);
    const command_result = tool_call.get("command_result").?.object;
    try std.testing.expectEqualStrings("command", command_result.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 0), command_result.get("exit_code").?.integer);
    try std.testing.expectEqual(@as(i64, 2), command_result.get("stdout_bytes").?.integer);
}

test "final ask json reports the resolved provider or null" {
    const alloc = std.testing.allocator;

    const routed = PromptRunResult{
        .exit_code = 0,
        .assistant_output = try alloc.dupe(u8, "ok"),
        .model = try alloc.dupe(u8, "anthropic/claude-sonnet-5"),
        .resolved_provider = try alloc.dupe(u8, "bedrock"),
    };
    defer routed.deinit(alloc);
    const routed_json = try renderFinalJsonResult(alloc, routed);
    defer alloc.free(routed_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, routed_json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("bedrock", parsed.value.object.get("resolved_provider").?.string);

    const unrouted = PromptRunResult{
        .exit_code = 0,
        .assistant_output = try alloc.dupe(u8, "ok"),
    };
    defer unrouted.deinit(alloc);
    const unrouted_json = try renderFinalJsonResult(alloc, unrouted);
    defer alloc.free(unrouted_json);
    var parsed_unrouted = try std.json.parseFromSlice(std.json.Value, alloc, unrouted_json, .{});
    defer parsed_unrouted.deinit();
    try std.testing.expect(parsed_unrouted.value.object.get("resolved_provider").? == .null);
}

test "runWithDeps honors no-save by skipping ask session stores" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    test_initialize_session_store_calls = 0;
    var deps = testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, testProcessQueuedPromptChecksExecOnlyTerminal);
    deps.initialize_session_stores = testCountSessionStores;

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--no-save", "hello" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqual(@as(usize, 0), test_initialize_session_store_calls);
}

test "runWithDeps retains full terminal projection with saved capability" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const test_home = try TestAskHome.install(alloc, home);
    defer test_home.deinit();

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testPresentKeySavedStartup,
    );
    deps.initialize_session_stores = initializeSessionStoresDefault;
    deps.process_queued_prompt = testProcessQueuedPromptChecksFullTerminal;

    const exit_code = try runWithDeps(alloc, &.{"hello"}, testConfig(), deps);

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("assistant text", stdout_capture.bytes.items);
}

test "exec-only terminal projection propagates view allocation failure" {
    var failing = std.testing.FailingAllocator.init(
        testing_allocator.no_resize,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        buildAskGatewayToolProjection(
            failing.allocator(),
            test_mode_registry,
            builtin_tools.advertisement_set,
            "inspect",
            .{},
            false,
        ),
    );
}

const TestAskHome = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, home: []const u8) !*TestAskHome {
        const self = try alloc.create(TestAskHome);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        try self.map.put("HOME", home);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestAskHome) void {
        io_mod.resetEnvironForTest();
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

test "fx ask renders one-off resume denial in text and JSON modes" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        args: []const [:0]const u8,
        json: bool,
    }{
        .{
            .args = &.{ "--resume", "one-off-child", "continue" },
            .json = false,
        },
        .{
            .args = &.{ "--json", "--resume", "one-off-child", "continue" },
            .json = true,
        },
    };
    for (cases) |case| {
        var stdout_capture: TestCapture = .{};
        defer stdout_capture.deinit(alloc);
        var stderr_capture: TestCapture = .{};
        defer stderr_capture.deinit(alloc);
        var deps = testPromptRunDeps(
            &stdout_capture,
            &stderr_capture,
            testPresentKeySavedStartup,
        );
        deps.initialize_session_stores = testInitializeSessionStoresOneOffDenied;

        const exit_code = try runWithDeps(alloc, case.args, testConfig(), deps);

        try std.testing.expectEqual(@as(u8, 1), exit_code);
        if (case.json) {
            var parsed = try std.json.parseFromSlice(
                std.json.Value,
                alloc,
                stdout_capture.bytes.items,
                .{},
            );
            defer parsed.deinit();
            try std.testing.expectEqualStrings(
                "OneOffSessionNotResumable",
                parsed.value.object.get("error").?.string,
            );
            try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
        } else {
            try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
            try std.testing.expectEqualStrings(
                "fx ask: subagent child sessions cannot be resumed directly; message the named agent from its parent session\n",
                stderr_capture.bytes.items,
            );
        }
    }
}

fn expectAskSessionStoresUnavailable(ctx: *const AskContext) !void {
    try std.testing.expect(ctx.v2_store == null);
    try std.testing.expect(ctx.v2 == null);
    try std.testing.expect(ctx.subagent_host == null);
}

fn exerciseSavedAskSessionStoreAllocation(
    alloc: Allocator,
    enforce_borrow_invariant: bool,
) !void {
    const setup_alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const home = try io_mod.dirRealpathAlloc(setup_alloc, tmp.dir, "home");
    defer setup_alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(
        setup_alloc,
        tmp.dir,
        "workspace",
    );
    defer setup_alloc.free(workspace);

    const test_home = try TestAskHome.install(setup_alloc, home);
    defer test_home.deinit();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(setup_alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(setup_alloc);
    const deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testPresentKeyStartup,
    );
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        deps,
        workspace,
    );
    defer ctx.deinit();
    ctx.session.setConversationLanguageFromUserMessage("persist this turn");

    ctx.initializeSessionStores() catch {
        _ = enforce_borrow_invariant;
        return;
    };
    _ = enforce_borrow_invariant;
}

test "saved ask allocation failures keep managed borrows owned" {
    const backing = testing_allocator.no_resize;
    var counting = std.testing.FailingAllocator.init(backing, .{});
    try exerciseSavedAskSessionStoreAllocation(counting.allocator(), false);

    for (0..counting.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            backing,
            .{ .fail_index = fail_index },
        );
        exerciseSavedAskSessionStoreAllocation(
            failing.allocator(),
            true,
        ) catch |err| {
            std.debug.print(
                "saved ask allocation fail_index={d} violated ownership: {s}\n",
                .{ fail_index, @errorName(err) },
            );
            return err;
        };
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(
            failing.allocated_bytes,
            failing.freed_bytes,
        );
    }
}

test "saved ask classifies unsafe store failure by request mode" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    var blocker = try tmp.dir.createFile(io_mod.getIo(), "home/.fx", .{});
    blocker.close(io_mod.getIo());

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const test_home = try TestAskHome.install(alloc, home);
    defer test_home.deinit();

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var fresh_ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(
            &stdout_capture,
            &stderr_capture,
            testPresentKeyStartup,
        ),
        workspace,
    );
    defer fresh_ctx.deinit();

    try fresh_ctx.initializeSessionStores();

    try std.testing.expectEqualStrings(
        "fx ask: warning: session persistence unavailable; error=SessionPathUnsafe; continuing without saving\n",
        stderr_capture.bytes.items,
    );
    try expectAskSessionStoresUnavailable(&fresh_ctx);

    stderr_capture.bytes.clearRetainingCapacity();
    var resume_ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(
            &stdout_capture,
            &stderr_capture,
            testPresentKeyStartup,
        ),
        workspace,
    );
    defer resume_ctx.deinit();
    resume_ctx.requested_resume = .last;

    try std.testing.expectError(
        error.SessionPathUnsafe,
        resume_ctx.initializeSessionStores(),
    );

    try std.testing.expectEqual(@as(usize, 0), stderr_capture.bytes.items.len);
    try expectAskSessionStoresUnavailable(&resume_ctx);
}

test "saved ask propagates store allocation failure" {
    const setup_alloc = testing_allocator.no_resize;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const home = try io_mod.dirRealpathAlloc(setup_alloc, tmp.dir, "home");
    defer setup_alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(
        setup_alloc,
        tmp.dir,
        "workspace",
    );
    defer setup_alloc.free(workspace);
    const test_home = try TestAskHome.install(setup_alloc, home);
    defer test_home.deinit();

    var failing = std.testing.FailingAllocator.init(
        setup_alloc,
        .{ .fail_index = 0 },
    );
    const alloc = failing.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(setup_alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(setup_alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(
            &stdout_capture,
            &stderr_capture,
            testPresentKeyStartup,
        ),
        workspace,
    );
    defer ctx.deinit();

    try std.testing.expectError(
        error.OutOfMemory,
        ctx.initializeSessionStores(),
    );

    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), stderr_capture.bytes.items.len);
    try expectAskSessionStoresUnavailable(&ctx);
}

test "saved ask initializes the direct subagent host" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    const test_home = try TestAskHome.install(alloc, home);
    defer test_home.deinit();

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), workspace);
    defer ctx.deinit();
    ctx.session.setConversationLanguageFromUserMessage("run a command");

    try ctx.initializeSessionStores();

    try std.testing.expect(ctx.subagent_host != null);
    try std.testing.expectEqualStrings(workspace, ctx.subagent_host.?.managed.services.lifecycle.workspace_root);
    try std.testing.expect(ctx.v2 != null);
}

test "parse options trims explicit stdin fallback" {
    var options = try parseOptionsWithStdin(std.testing.allocator, &.{}, .{ .bytes = " \n prompt from stdin \t" });
    defer options.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("prompt from stdin", options.prompt);
}

test "parse options rejects model-unsafe prompt text from arguments and stdin" {
    try std.testing.expectError(
        error.InvalidPromptText,
        parseOptionsWithStdin(std.testing.allocator, &.{"bad\x00prompt"}, .tty),
    );
    try std.testing.expectError(
        error.InvalidPromptText,
        parseOptionsWithStdin(std.testing.allocator, &.{}, .{ .bytes = "bad\xffprompt" }),
    );
}

test "the removed --resume-id spelling fails with a hint" {
    var problem: AskUsageProblem = .none;
    try std.testing.expectError(
        error.InvalidAskArgs,
        parseAskOptions(std.testing.allocator, &.{ "--resume-id", "session.v3", "continue" }, .tty, &problem),
    );
    try std.testing.expectEqualStrings("use --resume <id>", problem.flag.removed.replacement);
}

test "parse options keeps the last resume target and rejects no-save resume" {
    var options = try parseOptionsWithStdin(
        std.testing.allocator,
        &.{ "--resume", "last", "--resume", "session.v3", "continue" },
        .tty,
    );
    defer options.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("session.v3", options.resume_target.?.id);
    try std.testing.expectError(
        error.NoSaveResumeConflict,
        parseOptionsWithStdin(
            std.testing.allocator,
            &.{ "--no-save", "--resume", "last", "continue" },
            .tty,
        ),
    );
    try std.testing.expectError(
        error.NoSaveResumeConflict,
        parseOptionsWithStdin(
            std.testing.allocator,
            &.{ "--resume", "session.v3", "--no-save", "continue" },
            .tty,
        ),
    );
}

test "ask usage survives normal and typed error result capture" {
    const alloc = std.testing.allocator;
    const Outcome = enum { success, read_failed };
    inline for (std.meta.tags(Outcome)) |outcome| {
        const Process = struct {
            fn run(agent: *agent_runtime.Agent, deps: *const agent_runtime.AgentRuntimeDeps, _: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, _: agent_runtime.Config, job: worker_runtime.QueuedPrompt) !void {
                agent.startTurn();
                agent.observeUsage(.{ .input_tokens = 10, .output_tokens = 20 });
                agent.observeUsage(.{ .input_tokens = 7, .output_tokens = 3 });
                try testPushAssistantText(deps, "reported usage");
                if (std.mem.eql(u8, job.prompt, "read_failed")) return error.ReadFailed;
            }
        };
        var stdout_capture: TestCapture = .{};
        defer stdout_capture.deinit(alloc);
        var stderr_capture: TestCapture = .{};
        defer stderr_capture.deinit(alloc);
        var deps = testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, Process.run);
        deps.stdout_is_tty = TestTty.no;
        const exit_code = try runWithDeps(alloc, &.{ "--json", "--no-save", @tagName(outcome) }, testConfig(), deps);
        try std.testing.expectEqual(@as(u8, if (outcome == .success) 0 else 1), exit_code);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, stdout_capture.bytes.items, .{});
        defer parsed.deinit();
        const usage = parsed.value.object.get("usage").?.object;
        try std.testing.expectEqual(@as(i64, 17), usage.get("input_tokens").?.integer);
        try std.testing.expectEqual(@as(i64, 23), usage.get("output_tokens").?.integer);
        try std.testing.expectEqualStrings("reported usage", parsed.value.object.get("output").?.string);
        try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
        switch (outcome) {
            .success => try std.testing.expect(parsed.value.object.get("error") == null),
            .read_failed => try std.testing.expectEqualStrings("ReadFailed", parsed.value.object.get("error").?.string),
        }
    }
}

test "ask usage JSON distinguishes unavailable totals from reported zero" {
    const alloc = std.testing.allocator;
    const json = try renderFinalJsonResult(alloc, .{
        .exit_code = 0,
        .assistant_output = &.{},
        .usage = .{ .input_tokens = 0 },
    });
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const usage = parsed.value.object.get("usage").?.object;
    try std.testing.expectEqual(@as(i64, 0), usage.get("input_tokens").?.integer);
    try std.testing.expect(usage.get("output_tokens").? == .null);
}

test "render final JSON preserves shape escaping order and newline" {
    const alloc = std.testing.allocator;
    const tool_calls = try alloc.alloc(ToolCallRecord, 1);
    tool_calls[0] = .{
        .name = try alloc.dupe(u8, "read_file"),
        .status = try alloc.dupe(u8, "success"),
    };
    const result = PromptRunResult{
        .exit_code = 0,
        .assistant_output = try alloc.dupe(u8, "hello \"zig\"\n"),
        .model = try alloc.dupe(u8, "model-x"),
        .session_id = try alloc.dupe(u8, "123"),
        .tool_calls = tool_calls,
        .step_count = 2,
    };
    defer result.deinit(alloc);

    const json = try renderFinalJsonResult(alloc, result);
    defer alloc.free(json);

    try std.testing.expectEqualStrings(
        "{\"output\":\"hello \\\"zig\\\"\\n\",\"final_output\":\"\",\"exit_code\":0,\"model\":\"model-x\",\"resolved_provider\":null,\"session_id\":\"123\",\"steps\":2,\"tool_calls\":[{\"name\":\"read_file\",\"status\":\"success\"}],\"usage\":{\"input_tokens\":null,\"output_tokens\":null}}\n",
        json,
    );
}

test "render final JSON emits empty tool call array" {
    const alloc = std.testing.allocator;
    const result = PromptRunResult{
        .exit_code = 1,
        .assistant_output = try alloc.dupe(u8, ""),
    };
    defer result.deinit(alloc);

    const json = try renderFinalJsonResult(alloc, result);
    defer alloc.free(json);

    try std.testing.expectEqualStrings(
        "{\"output\":\"\",\"final_output\":\"\",\"exit_code\":1,\"model\":\"\",\"resolved_provider\":null,\"session_id\":\"\",\"steps\":0,\"tool_calls\":[],\"usage\":{\"input_tokens\":null,\"output_tokens\":null}}\n",
        json,
    );
}

test "render final JSON reports the successful recovery attempt" {
    const alloc = std.testing.allocator;
    const result = PromptRunResult{
        .exit_code = 0,
        .assistant_output = try alloc.dupe(u8, "recovered"),
        .recovery = .{
            .kind = .recovered,
            .attempt = 3,
        },
    };
    defer result.deinit(alloc);

    const json = try renderFinalJsonResult(alloc, result);
    defer alloc.free(json);

    try std.testing.expect(std.mem.find(u8, json, ",\"recovery\":{\"state\":\"recovered\",\"attempt\":3}}") != null);
}

test "render final JSON names what a needs-you status needs" {
    const alloc = std.testing.allocator;
    const result = PromptRunResult{
        .exit_code = 1,
        .assistant_output = try alloc.dupe(u8, ""),
        .recovery = .{
            .kind = .need_user,
            .need = .rejected,
            .text = testRecoveryText("The provider rejected this request · press Esc"),
            .attempt = 1,
        },
    };
    defer result.deinit(alloc);

    const json = try renderFinalJsonResult(alloc, result);
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const recovery = parsed.value.object.get("recovery").?.object;
    try std.testing.expectEqualStrings("need_user", recovery.get("state").?.string);
    try std.testing.expectEqualStrings("rejected", recovery.get("need").?.string);
    try std.testing.expectEqual(@as(i64, 1), recovery.get("attempt").?.integer);
    try std.testing.expectEqualStrings("The provider rejected this request · press Esc", recovery.get("message").?.string);
}

test "render final JSON includes the latest terminal recovery diagnostic" {
    const alloc = std.testing.allocator;
    const result = PromptRunResult{
        .exit_code = 1,
        .assistant_output = try alloc.dupe(u8, ""),
        .recovery = .{
            .kind = .terminal_provider_error,
            .attempt = 2,
            .cause = .provider_unavailable,
            .diagnostic = types.ModelFailureDiagnostic.init(
                "HTTP 503 · no_available_providers: No providers are currently available",
            ),
        },
    };
    defer result.deinit(alloc);

    const json = try renderFinalJsonResult(alloc, result);
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const recovery = parsed.value.object.get("recovery").?.object;
    try std.testing.expectEqualStrings("failed", recovery.get("state").?.string);
    try std.testing.expectEqualStrings(
        "⚠ Provider unavailable · HTTP 503 · no_available_providers: No providers are currently available · stopped after 2 attempts",
        recovery.get("message").?.string,
    );
}

test "cli json records built in web_search completion" {
    const alloc = std.testing.allocator;
    const records = try alloc.alloc(ToolCallRecord, 1);
    records[0] = .{
        .name = try alloc.dupe(u8, "WebSearch"),
        .status = try alloc.dupe(u8, "success"),
        .web_search_completion = .{ .searches = 3, .duration_ms = 42 },
    };
    const result = PromptRunResult{
        .exit_code = 0,
        .assistant_output = try alloc.dupe(u8, ""),
        .tool_calls = records,
    };
    defer result.deinit(alloc);

    const rendered = try renderFinalJsonResult(alloc, result);
    defer alloc.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, rendered, .{});
    defer parsed.deinit();
    const web_search = parsed.value.object.get("tool_calls").?.array.items[0].object.get("WebSearch").?.object;
    try std.testing.expectEqual(@as(i64, 3), web_search.get("searches").?.integer);
    try std.testing.expectEqual(@as(i64, 42), web_search.get("duration_ms").?.integer);
}

test "fx ask JSON captures HTTP 413 prompt-too-long blocker" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "--no-save", "hello" },
        testConfig(),
        testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, testProcessQueuedPromptHttp413),
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "fx ask: HTTP 413: provider payload rejected") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, stdout_capture.bytes.items, .{});
    defer parsed.deinit();
    const output = parsed.value.object.get("output").?.string;
    try std.testing.expect(std.mem.find(u8, output, "HTTP 413") != null);
    try std.testing.expect(std.mem.find(u8, output, "prompt_too_long=true") != null);
    try std.testing.expect(std.mem.find(u8, output, "Provider rejected the prompt as too large") != null);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("exit_code").?.integer);
}

test "fx ask formats restricted-provider HTTP errors without raw JSON" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "--no-save", "hello" },
        testConfig(),
        testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, testProcessQueuedPromptRestrictedProvider),
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "fx ask: API access denied · HTTP 403 · Provider: wafer") != null);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "{\"error\"") == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, stdout_capture.bytes.items, .{});
    defer parsed.deinit();
    const output = parsed.value.object.get("output").?.string;
    try std.testing.expect(std.mem.find(u8, output, "API access denied · HTTP 403 · Provider: wafer") != null);
    try std.testing.expect(std.mem.find(u8, output, "{\"error\"") == null);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("exit_code").?.integer);
}

test "fx ask text and JSON share the selected auth failure facts" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "--no-save", "hello" },
        testConfig(),
        testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, testProcessQueuedPromptUnauthorized),
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings(
        "fx ask: AI_GATEWAY_API_KEY authentication failed · HTTP 401\n",
        stderr_capture.bytes.items,
    );
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, stdout_capture.bytes.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("exit_code").?.integer);
    try std.testing.expectEqualStrings(
        "AI_GATEWAY_API_KEY authentication failed · HTTP 401\n",
        parsed.value.object.get("output").?.string,
    );
    const auth_failure = parsed.value.object.get("auth_failure").?.object;
    try std.testing.expectEqualStrings("AI_GATEWAY_API_KEY", auth_failure.get("source").?.string);
    try std.testing.expectEqualStrings("http_unauthorized", auth_failure.get("reason").?.string);
    try std.testing.expectEqual(@as(i64, 401), auth_failure.get("http_status").?.integer);
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, "secret-key") == null);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "secret-key") == null);
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, "\x1b") == null);
}

test "saved API key 401 leaves no saved session" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const test_home = try TestAskHome.install(alloc, home);
    defer test_home.deinit();

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testPresentKeySavedStartup,
    );
    deps.process_queued_prompt = testProcessQueuedPromptUnauthorized;
    deps.initialize_session_stores = initializeSessionStoresDefault;

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "hello" },
        testConfig(),
        deps,
    );
    try std.testing.expectEqual(@as(u8, 1), exit_code);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        stdout_capture.bytes.items,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "",
        parsed.value.object.get("session_id").?.string,
    );
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("steps").?.integer);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("tool_calls").?.array.items.len);
    try std.testing.expect(parsed.value.object.get("auth_failure") != null);

    var store = try session_adapter.Store.open(alloc, home);
    defer store.deinit(alloc);
    try std.testing.expectError(
        error.NoSavedSessions,
        session_adapter.Session.resumeSession(alloc, &store, .last, "/tmp/fx-test", .ask),
    );
}

test "fx ask JSON records permission-denied tool calls as error status" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), root);
    defer ctx.deinit();
    ctx.output_mode = .json;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try recordToolCallRejected(@ptrCast(&ctx), arena, .{
        .id = "cmd",
        .name = "Bash",
        .arguments_json = "{\"command\":\"printf secret\"}",
    }, "{\"error\":{\"type\":\"tool_permission_denied\"}}", "{\"kind\":\"command\"}");

    try std.testing.expectEqual(@as(usize, 1), ctx.tool_call_records.items.len);
    try std.testing.expectEqualStrings("Bash", ctx.tool_call_records.items[0].name);
    try std.testing.expectEqualStrings("error", ctx.tool_call_records.items[0].status);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"command\"}",
        ctx.tool_call_records.items[0].command_result_json.?,
    );
}

test "fx ask JSON keeps shell runtime error identity without an action" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var ctx = AskContext.init(alloc, testConfig(), .{
        .context_registry = test_no_context_registry,
        .tool_set = builtin_tools.advertisement_set,
    }, root);
    defer ctx.deinit();
    ctx.output_mode = .json;

    captureToolExecutionError(&ctx, .{
        .call_allocator = alloc,
        .result_allocator = alloc,
        .call = .{
            .id = "shell-runtime-error",
            .name = "Bash",
            .arguments_json = "{\"command\":\"sleep 1\"}",
        },
        .authority = .ordinary,
        .session_grants = &.{},
        .advertised_dynamic_tool_names = &.{},
        .max_tool_result_bytes = 4096,
    }, error.ExecutionNotFound);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try recordToolCallRejected(@ptrCast(&ctx), arena_state.allocator(), .{
        .id = "shell-invalid-action",
        .name = "Bash",
        .arguments_json = "{\"action\":\"legacy\"}",
    }, "Invalid shell action", null);

    const records = try takeToolCallRecords(&ctx, alloc);
    const result = PromptRunResult{
        .exit_code = 1,
        .assistant_output = try alloc.dupe(u8, ""),
        .tool_calls = records,
    };
    defer result.deinit(alloc);
    const rendered = try renderFinalJsonResult(alloc, result);
    defer alloc.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, rendered, .{});
    defer parsed.deinit();
    const record = parsed.value.object.get("tool_calls").?.array.items[0].object;
    try std.testing.expect(record.get("action") == null);
    const failure = (record.get("error") orelse return error.TestExpectedEqual).object;
    try std.testing.expectEqualStrings("runtime_failed", failure.get("category").?.string);
    try std.testing.expectEqualStrings("ExecutionNotFound", failure.get("code").?.string);

    const rejected = parsed.value.object.get("tool_calls").?.array.items[1].object;
    try std.testing.expect(rejected.get("action") == null);
    const rejected_failure = (rejected.get("error") orelse
        return error.TestExpectedEqual).object;
    try std.testing.expectEqualStrings(
        "rejected",
        rejected_failure.get("category").?.string,
    );
    try std.testing.expectEqualStrings(
        "rejected",
        rejected_failure.get("code").?.string,
    );
}

test "shell diagnostic codes remain bounded semantic identifiers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "termination_indeterminate",
        shell_failure_code(arena, .command_failed, .{
            .status = .failure,
            .model_output = "failure",
            .command_result_json = "{\"termination_indeterminate\":true}",
        }),
    );
    try std.testing.expectEqualStrings(
        "nonzero_exit",
        shell_failure_code(arena, .command_failed, .{
            .status = .failure,
            .model_output = "failure",
            .command_result_json = "{\"exit_code\":7}",
        }),
    );
    try std.testing.expectEqualStrings(
        "command_failed",
        shell_failure_code(arena, .command_failed, .{
            .status = .failure,
            .model_output = "failure",
            .command_result_json = "{\"exit_code\":0}",
        }),
    );
    try std.testing.expectEqualStrings(
        "ExecutionNotFound",
        shell_failure_code(arena, .tool_failed, .{
            .status = .failure,
            .model_output = "{\"error\":{\"tool\":\"Bash\",\"code\":\"ExecutionNotFound\"}}",
        }),
    );
    try std.testing.expectEqualStrings(
        "tool_failed",
        shell_failure_code(arena, .tool_failed, .{
            .status = .failure,
            .model_output = "{\"error\":{\"tool\":\"Bash\",\"code\":\"secret value\"}}",
        }),
    );
}

test "fx ask JSON permission-denied capture is best effort under allocation failure" {
    var failing = std.testing.FailingAllocator.init(
        testing_allocator.no_resize,
        .{ .fail_index = 0 },
    );
    var ctx = AskContext.init(
        failing.allocator(),
        testConfig(),
        .{
            .context_registry = test_no_context_registry,
            .tool_set = builtin_tools.advertisement_set,
        },
        "/tmp/workspace",
    );
    defer ctx.deinit();
    ctx.output_mode = .json;

    try recordToolCallRejected(@ptrCast(&ctx), std.testing.allocator, .{
        .id = "cmd",
        .name = "Bash",
        .arguments_json = "{\"command\":\"printf secret\"}",
    }, "{\"error\":{\"type\":\"tool_permission_denied\"}}", null);

    try std.testing.expectEqual(@as(usize, 0), ctx.tool_call_records.items.len);
}

test "fx ask JSON captures parallel tool results without corrupting records" {
    const alloc = std.heap.c_allocator;
    const thread_count = 16;
    const calls_per_thread = 256;
    const expected_count = thread_count * calls_per_thread;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "workspace");
    defer std.testing.allocator.free(root);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(std.testing.allocator);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(std.testing.allocator);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(
            &stdout_capture,
            &stderr_capture,
            testPresentKeyStartup,
        ),
        root,
    );
    defer ctx.deinit();
    ctx.output_mode = .json;
    try ctx.tool_call_records.ensureTotalCapacity(alloc, expected_count);

    const CaptureWorker = struct {
        ctx: *AskContext,
        ready: *std.atomic.Value(usize),
        start: *std.atomic.Value(bool),
        failed: *std.atomic.Value(bool),

        fn run(self: @This()) void {
            _ = self.ready.fetchAdd(1, .seq_cst);
            while (!self.start.load(.seq_cst)) {
                std.atomic.spinLoopHint();
            }

            for (0..calls_per_thread) |_| {
                var arena_state = std.heap.ArenaAllocator.init(alloc);
                const arena = arena_state.allocator();
                _ = executeToolCallAuthorized(@ptrCast(self.ctx), .{
                    .call_allocator = arena,
                    .result_allocator = arena,
                    .call = .{
                        .id = "parallel-capture",
                        .name = "glob_files",
                        .arguments_json = "{\"pattern\":\"*\"}",
                    },
                    .authority = .ordinary,
                    .session_grants = &.{},
                    .advertised_dynamic_tool_names = &.{},
                    .max_tool_result_bytes = 4096,
                }) catch {
                    self.failed.store(true, .seq_cst);
                    arena_state.deinit();
                    return;
                };
                arena_state.deinit();
            }
        }
    };

    var ready = std.atomic.Value(usize).init(0);
    var start = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, CaptureWorker.run, .{CaptureWorker{
            .ctx = &ctx,
            .ready = &ready,
            .start = &start,
            .failed = &failed,
        }});
    }
    while (ready.load(.seq_cst) != thread_count) {
        std.atomic.spinLoopHint();
    }
    start.store(true, .seq_cst);
    for (threads) |thread| thread.join();

    try std.testing.expect(!failed.load(.seq_cst));
    try std.testing.expectEqual(expected_count, ctx.tool_call_records.items.len);
    for (ctx.tool_call_records.items) |record| {
        try std.testing.expectEqualStrings("glob_files", record.name);
        try std.testing.expectEqualStrings("success", record.status);
    }
}

fn checkAskJsonCaptureAllocationFailures(alloc: Allocator) !void {
    var ctx = AskContext.init(alloc, testConfig(), .{
        .context_registry = test_no_context_registry,
        .tool_set = builtin_tools.advertisement_set,
    }, "/tmp/workspace");
    defer ctx.deinit();
    ctx.output_mode = .json;
    try ctx.assistant_output.appendSlice(alloc, "assistant");

    try appendToolCallRecord(
        &ctx,
        .{
            .id = "capture",
            .name = "AskUserQuestion",
            .arguments_json = "{\"questions\":[{\"question\":\"Continue?\"}]}",
        },
        "success",
        .{
            .model_output = "contents",
            .command_result_json = "{\"ok\":true}",
        },
        null,
        null,
    );

    const result = try takePromptRunResult(&ctx, alloc);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("assistant", result.assistant_output);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings(
        "AskUserQuestion",
        result.tool_calls[0].name,
    );
    try std.testing.expectEqualStrings("success", result.tool_calls[0].status);
    try std.testing.expectEqualStrings(
        "{\"ok\":true}",
        result.tool_calls[0].command_result_json.?,
    );
    try std.testing.expectEqualStrings(
        "Continue?",
        result.tool_calls[0].ask_question_text.?,
    );
}

test "fx ask JSON capture cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        checkAskJsonCaptureAllocationFailures,
        .{},
    );
}

test "fx ask JSON records ask_user_question text for matching assertions" {
    const alloc = std.testing.allocator;
    const records = try alloc.alloc(ToolCallRecord, 1);
    records[0] = .{
        .name = try alloc.dupe(u8, "AskUserQuestion"),
        .status = try alloc.dupe(u8, "success"),
        .ask_question_text = try alloc.dupe(u8, "What is your GitHub handle?"),
    };
    const result = PromptRunResult{
        .exit_code = 0,
        .assistant_output = try alloc.dupe(u8, ""),
        .tool_calls = records,
    };
    defer result.deinit(alloc);

    const rendered = try renderFinalJsonResult(alloc, result);
    defer alloc.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, rendered, .{});
    defer parsed.deinit();
    const tool_call = parsed.value.object.get("tool_calls").?.array.items[0].object;
    try std.testing.expectEqualStrings("AskUserQuestion", tool_call.get("name").?.string);
    try std.testing.expectEqualStrings("What is your GitHub handle?", tool_call.get("question").?.string);
}

test "fx ask JSON clips ask_user_question text at a UTF-8 boundary" {
    const alloc = std.testing.allocator;
    var question_bytes: [257]u8 = undefined;
    @memset(question_bytes[0..255], 'a');
    question_bytes[255] = 0xc3;
    question_bytes[256] = 0xa9;
    const arguments_json = try alloc.print(
        "{{\"questions\":[{{\"question\":\"{s}\"}}]}}",
        .{question_bytes[0..]},
    );
    defer alloc.free(arguments_json);

    var ctx = AskContext.init(alloc, testConfig(), .{
        .context_registry = test_no_context_registry,
        .tool_set = builtin_tools.advertisement_set,
    }, "/tmp/workspace");
    defer ctx.deinit();
    ctx.output_mode = .json;
    try appendToolCallRecord(
        &ctx,
        .{
            .id = "question",
            .name = "AskUserQuestion",
            .arguments_json = arguments_json,
        },
        "success",
        null,
        null,
        null,
    );

    const result = try takePromptRunResult(&ctx, alloc);
    defer result.deinit(alloc);
    const rendered = try renderFinalJsonResult(alloc, result);
    defer alloc.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, rendered, .{});
    defer parsed.deinit();

    const question = parsed.value.object.get("tool_calls").?.array.items[0].object.get("question").?;
    try std.testing.expect(question == .string);
    if (question != .string) return error.TestUnexpectedResult;
    try std.testing.expect(std.unicode.utf8ValidateSlice(question.string));
    try std.testing.expectEqual(@as(usize, 255), question.string.len);
}

test "json run with missing API key prints diagnostic then final object" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    const exit_code = try runWithDeps(alloc, &.{ "--json", "hello" }, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testMissingKeyStartup));

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings("fx ask: " ++ credentials.missing_credential_message ++ "\n", stderr_capture.bytes.items);
    try std.testing.expectEqualStrings(
        "{\"output\":\"\",\"final_output\":\"\",\"exit_code\":1,\"model\":\"\",\"resolved_provider\":null,\"session_id\":\"\",\"steps\":0,\"tool_calls\":[],\"usage\":{\"input_tokens\":null,\"output_tokens\":null},\"error\":\"MissingCredentials\"}\n",
        stdout_capture.bytes.items,
    );
}

test "json run with session setup failure still emits final object" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.initialize_session_stores = testFailSessionStores;

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "--resume", "corrupt-session", "hello" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, "\"exit_code\":1") != null);
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, "\"error\":\"InvalidSessionFormat\"") != null);
}

test "missing API key returns before project context gathering" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    test_gather_project_context_calls = 0;
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testMissingKeyStartup);
    deps.context_registry = test_count_context_registry;

    const exit_code = try runWithDeps(alloc, &.{"hello"}, testConfig(), deps);

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqual(@as(usize, 0), test_gather_project_context_calls);
}

test "fx ask forwards its catalog and deduplicates repeated discovery warnings" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    var deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testPresentKeyTruncatedSkillCatalogStartup,
    );
    deps.load_skills = testLoadTruncatedSkillsWithDiagnostic;
    deps.process_queued_prompt = testProcessQueuedPromptRepeatsSkillDiagnostic;

    const exit_code = try runWithDeps(alloc, &.{"hello"}, testConfig(), deps);

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, stderr_capture.bytes.items, "skill discovery warning:"),
    );
}

test "fx ask carries resolved auto mode and initial registry context into the queued prompt" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    TestContextRegistryFixture.reset(test_registry_static_context, 1);
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.context_registry = test_cli_context_registry;
    deps.process_queued_prompt = TestContextRegistryFixture.process;

    const exit_code = try runWithDeps(alloc, &.{ "--auto", "hello" }, testConfig(), deps);

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqual(@as(usize, 1), TestContextRegistryFixture.gather_calls);
    try std.testing.expectEqual(
        PermissionMode.auto,
        TestContextRegistryFixture.transient_permission_mode orelse return error.TestExpectedEqual,
    );
}

test "default fx ask passes canonical image paths as initial context targets" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "target.png", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\nrest");
    }
    const image_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "target.png");
    defer alloc.free(image_path);
    const image_path_z = try alloc.dupeSentinel(u8, image_path, 0);
    defer alloc.free(image_path_z);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    TestContextRegistryFixture.reset(test_registry_static_context, 1);
    TestContextRegistryFixture.expected_target_paths = &.{image_path};
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.context_registry = test_cli_context_registry;
    deps.process_queued_prompt = TestContextRegistryFixture.process;

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--image", image_path_z, "describe" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqual(@as(usize, 1), TestContextRegistryFixture.gather_calls);
    try std.testing.expectEqual(@as(usize, 1), TestContextRegistryFixture.process_calls);
    try std.testing.expect(TestContextRegistryFixture.targets_match);
}

test "default fx ask omits disabled registry context without gathering" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    TestContextRegistryFixture.reset(null, 0);
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyNoContextStartup);
    deps.context_registry = test_cli_context_registry;
    deps.process_queued_prompt = TestContextRegistryFixture.process;

    const exit_code = try runWithDeps(alloc, &.{"hello"}, testConfig(), deps);

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqual(@as(usize, 0), TestContextRegistryFixture.gather_calls);
}

test "default fx ask preserves project context gathering error mappings" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    const cases = [_]struct {
        err: context_contract.ProviderError,
        json: ?[]const u8,
    }{
        .{ .err = error.OutOfMemory, .json = null },
        .{ .err = error.NoSpaceLeft, .json = "{\"output\":\"\",\"final_output\":\"\",\"exit_code\":1,\"model\":\"\",\"resolved_provider\":null,\"session_id\":\"\",\"steps\":0,\"tool_calls\":[],\"usage\":{\"input_tokens\":null,\"output_tokens\":null},\"error\":\"NoSpaceLeft\"}\n" },
        .{ .err = error.WriteFailed, .json = "{\"output\":\"\",\"final_output\":\"\",\"exit_code\":1,\"model\":\"\",\"resolved_provider\":null,\"session_id\":\"\",\"steps\":0,\"tool_calls\":[],\"usage\":{\"input_tokens\":null,\"output_tokens\":null},\"error\":\"WriteFailed\"}\n" },
    };

    for (cases) |case| {
        TestContextRegistryFixture.reset(null, 1);
        TestContextRegistryFixture.gather_error = case.err;
        var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
        deps.context_registry = test_cli_context_registry;
        deps.process_queued_prompt = TestContextRegistryFixture.process;

        try std.testing.expectError(case.err, runWithDeps(alloc, &.{"hello"}, testConfig(), deps));
        try std.testing.expectEqual(@as(usize, 1), TestContextRegistryFixture.gather_calls);
        try std.testing.expectEqual(@as(usize, 0), TestContextRegistryFixture.process_calls);
        try std.testing.expectEqual(@as(usize, 0), stdout_capture.bytes.items.len);
        try std.testing.expectEqual(@as(usize, 0), stderr_capture.bytes.items.len);

        TestContextRegistryFixture.reset(null, 1);
        TestContextRegistryFixture.gather_error = case.err;
        if (case.json) |expected_json| {
            const exit_code = try runWithDeps(alloc, &.{ "--json", "hello" }, testConfig(), deps);
            try std.testing.expectEqual(@as(u8, 1), exit_code);
            try std.testing.expectEqualStrings(expected_json, stdout_capture.bytes.items);
        } else {
            try std.testing.expectError(
                case.err,
                runWithDeps(alloc, &.{ "--json", "hello" }, testConfig(), deps),
            );
            try std.testing.expectEqual(@as(usize, 0), stdout_capture.bytes.items.len);
        }
        try std.testing.expectEqual(@as(usize, 1), TestContextRegistryFixture.gather_calls);
        try std.testing.expectEqual(@as(usize, 0), TestContextRegistryFixture.process_calls);
        try std.testing.expectEqual(@as(usize, 0), stderr_capture.bytes.items.len);
        stdout_capture.bytes.clearRetainingCapacity();
        stderr_capture.bytes.clearRetainingCapacity();
    }
}

test "quiet suppresses streaming while quiet json captures final output" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    const quiet_exit = try runWithDeps(alloc, &.{ "--quiet", "hello" }, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup));
    try std.testing.expectEqual(@as(u8, 0), quiet_exit);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);

    stdout_capture.bytes.clearRetainingCapacity();
    stderr_capture.bytes.clearRetainingCapacity();

    const json_exit = try runWithDeps(alloc, &.{ "--quiet", "--json", "hello" }, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup));
    try std.testing.expectEqual(@as(u8, 0), json_exit);
    try std.testing.expect(std.mem.startsWith(u8, stdout_capture.bytes.items, "{\"output\":\"assistant text\",\"final_output\":\"\",\"exit_code\":0,\"model\":\"model\",\"resolved_provider\":null,\"session_id\":\""));
    try std.testing.expect(std.mem.endsWith(u8, stdout_capture.bytes.items, "\",\"steps\":0,\"tool_calls\":[],\"usage\":{\"input_tokens\":null,\"output_tokens\":null}}\n"));
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
}

test "fx ask JSON recovery keeps stdout structured and reports progress on stderr" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    const deps = testPromptRunDepsWithProcess(
        &stdout_capture,
        &stderr_capture,
        testProcessQueuedPromptRecoveryLifecycle,
    );

    const exit_code = try runWithDeps(alloc, &.{ "--json", "hello" }, testConfig(), deps);
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, stdout_capture.bytes.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("assistant text", parsed.value.object.get("output").?.string);
    const recovery = parsed.value.object.get("recovery").?.object;
    try std.testing.expectEqualStrings("recovered", recovery.get("state").?.string);
    try std.testing.expectEqual(@as(i64, 2), recovery.get("attempt").?.integer);
    try std.testing.expect(recovery.get("message") == null);

    try std.testing.expectEqualStrings(
        "[notice] Offline · next try in 2s · 0s\n[notice] Offline · retrying · attempt 2 · 2s\n",
        stderr_capture.bytes.items,
    );
}

test "fx ask JSON reports only the last request's recovery" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    const deps = testPromptRunDepsWithProcess(
        &stdout_capture,
        &stderr_capture,
        testProcessQueuedPromptRecoveredThenFailed,
    );

    const exit_code = try runWithDeps(alloc, &.{ "--json", "hello" }, testConfig(), deps);
    try std.testing.expectEqual(@as(u8, 1), exit_code);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, stdout_capture.bytes.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("exit_code").?.integer);

    try std.testing.expect(parsed.value.object.get("recovery") == null);
}

test "fx ask JSON reports the consumed attempt after retry admission failure" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    const deps = testPromptRunDepsWithProcess(
        &stdout_capture,
        &stderr_capture,
        testProcessQueuedPromptRetryAdmissionFailure,
    );

    const exit_code = try runWithDeps(alloc, &.{ "--json", "hello" }, testConfig(), deps);
    try std.testing.expectEqual(@as(u8, 1), exit_code);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, stdout_capture.bytes.items, .{});
    defer parsed.deinit();
    const recovery = parsed.value.object.get("recovery").?.object;
    try std.testing.expectEqualStrings("failed", recovery.get("state").?.string);
    try std.testing.expectEqual(@as(i64, 1), recovery.get("attempt").?.integer);
    try std.testing.expect(recovery.get("delay_seconds") == null);
    try std.testing.expectEqualStrings(
        "TestProviderSerializationFailed",
        parsed.value.object.get("error").?.string,
    );
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "next try in 4s") != null);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "stopped after 1 attempt") != null);
}

test "fx ask JSON preserves partial output on prompt failure" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDepsWithProcess(
        &stdout_capture,
        &stderr_capture,
        testProcessQueuedPromptPartialThenReadFailed,
    );
    deps.stdout_is_tty = TestTty.no;

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "--no-save", "hello" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, stdout_capture.bytes.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("partial résumé", parsed.value.object.get("output").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("exit_code").?.integer);
    try std.testing.expectEqualStrings("ReadFailed", parsed.value.object.get("error").?.string);
    try std.testing.expectEqualStrings("model", parsed.value.object.get("model").?.string);
    try std.testing.expectEqualStrings("", parsed.value.object.get("session_id").?.string);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("tool_calls").?.array.items.len);
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
}

test "fx ask raw output still propagates prompt failure" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDepsWithProcess(
        &stdout_capture,
        &stderr_capture,
        testProcessQueuedPromptPartialThenReadFailed,
    );
    deps.stdout_is_tty = TestTty.no;

    try std.testing.expectError(
        error.ReadFailed,
        runWithDeps(alloc, &.{ "--no-save", "hello" }, testConfig(), deps),
    );
    try std.testing.expectEqualStrings("partial résumé", stdout_capture.bytes.items);
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
}

test "text ask prints a resume hint naming the session on stderr only" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    const deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);

    try writeResumeHint(alloc, deps, "session-42", false);
    try std.testing.expectEqualStrings("To resume this session: fx -r session-42\n", stderr_capture.bytes.items);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
}

test "CLI tagged stream routes source output rendering and diagnostics by mode" {
    const alloc = std.testing.allocator;
    const source_spans = [_][]const u8{
        "# Heading\n",
        "\n**bold** [docs](https://example.com)\n",
    };
    const source_output = "# Heading\n\n**bold** [docs](https://example.com)\n";
    const rendered_span = "\x1b[1mbold\x1b[22m\n";

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer ctx.deinit();
    ctx.output_mode = .raw;

    const deps = agentRuntimeDeps(&ctx);
    try deps.push_text(deps.ctx, .{ .assistant_rendered = rendered_span });
    for (source_spans) |span| try deps.push_text(deps.ctx, .{ .assistant_source = span });

    try std.testing.expectEqualStrings(source_output, stdout_capture.bytes.items);
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), ctx.assistant_output.items.len);

    try deps.push_tool_lifecycle(deps.ctx, .{
        .authoritative_started = .{
            .id = .{ .turn_id = 1, .call_id = "read_1" },
            .reconciles_provisional_call_id = null,
            .tool_name = "read_file",
            .activity_kind = .read,
        },
    });
    try std.testing.expectEqual(@as(usize, 1), ctx.step_count);
    try deps.push_tool_lifecycle(deps.ctx, .{
        .progress = .{
            .id = .{ .turn_id = 1, .call_id = "read_1" },
            .text = "Reading src/main.zig",
        },
    });
    try std.testing.expectEqualStrings("Reading src/main.zig\n", stderr_capture.bytes.items);
    try deps.push_text(deps.ctx, .{ .assistant_source = "after **tool**\n" });
    try deps.push_text(deps.ctx, .{ .operational = "diagnostic\n" });

    try std.testing.expectEqualStrings(
        source_output ++ "\nafter **tool**\n",
        stdout_capture.bytes.items,
    );
    try std.testing.expectEqualStrings(
        "Reading src/main.zig\ndiagnostic\n",
        stderr_capture.bytes.items,
    );
    try std.testing.expectEqual(@as(usize, 1), ctx.step_count);
    try std.testing.expectEqual(@as(usize, 0), ctx.assistant_output.items.len);

    var json_stdout_capture: TestCapture = .{};
    defer json_stdout_capture.deinit(alloc);
    var json_stderr_capture: TestCapture = .{};
    defer json_stderr_capture.deinit(alloc);
    var json_ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(&json_stdout_capture, &json_stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer json_ctx.deinit();
    json_ctx.output_mode = .json;

    const json_deps = agentRuntimeDeps(&json_ctx);
    try json_deps.push_text(json_deps.ctx, .{ .assistant_rendered = rendered_span });
    for (source_spans) |span| try json_deps.push_text(json_deps.ctx, .{ .assistant_source = span });
    try json_deps.push_text(json_deps.ctx, .{ .operational = "diagnostic\n" });
    const finished = try types.dupeFinishedPrompt(std.heap.c_allocator, .{
        .turn = .{ .assistant = .{
            .user = .{ .text = @constCast("prompt") },
            .assistant = @constCast("final answer"),
        } },
        .terminal_outcome = .completed,
    });
    try json_deps.push_event(json_deps.ctx, .{ .finish_prompt = finished });

    try std.testing.expectEqualStrings(source_output, json_ctx.assistant_output.items);
    try std.testing.expectEqualStrings("final answer", json_ctx.final_output.items);
    try std.testing.expectEqualStrings("", json_stdout_capture.bytes.items);
    try std.testing.expectEqualStrings("diagnostic\n", json_stderr_capture.bytes.items);

    const result = try takePromptRunResult(&json_ctx, alloc);
    defer result.deinit(alloc);
    const rendered = try renderFinalJsonResult(alloc, result);
    defer alloc.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, rendered, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(source_output, parsed.value.object.get("output").?.string);
    try std.testing.expectEqualStrings("final answer", parsed.value.object.get("final_output").?.string);
}

test "CLI response restart preserves completed output and removes only the failed JSON preview" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer ctx.deinit();
    ctx.output_mode = .json;
    const deps = agentRuntimeDeps(&ctx);
    try deps.push_text(deps.ctx, .assistant_started);
    try deps.push_text(deps.ctx, .{ .assistant_source = "Completed tool commentary." });
    try deps.push_text(deps.ctx, .assistant_started);
    try deps.push_text(deps.ctx, .{ .assistant_source = "DISCARDED partial" });
    try deps.push_text(deps.ctx, .{ .assistant_restarted = "Restart notice\n" });
    try std.testing.expectEqualStrings("Completed tool commentary.DISCARDED partial", ctx.assistant_output.items);
    try deps.push_text(deps.ctx, .assistant_started);
    try deps.push_text(deps.ctx, .{ .assistant_source = "Replacement." });
    try std.testing.expectEqualStrings("Completed tool commentary.\n\nReplacement.", ctx.assistant_output.items);
    try std.testing.expectEqualStrings("Restart notice\n", stderr_capture.bytes.items);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);

    ctx.output_mode = .raw;
    try deps.push_text(deps.ctx, .{ .assistant_source = "partial" });
    try deps.push_text(deps.ctx, .{ .assistant_restarted = "\n\nRestart notice\n\n" });
    try deps.push_text(deps.ctx, .{ .assistant_source = "Replacement." });
    try std.testing.expectEqualStrings("partial\n\nRestart notice\n\nReplacement.", stdout_capture.bytes.items);
}

test "CLI keeps an unreplaced preview on failure and discards it on completion" {
    const alloc = std.testing.allocator;
    for ([_]types.TurnPresentationOutcome{ .paused, .failed, .interrupted, .completed }) |outcome| {
        var stdout_capture: TestCapture = .{};
        defer stdout_capture.deinit(alloc);
        var stderr_capture: TestCapture = .{};
        defer stderr_capture.deinit(alloc);
        var ctx = AskContext.init(
            alloc,
            testConfig(),
            testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
            "/tmp/workspace",
        );
        defer ctx.deinit();
        ctx.output_mode = .json;
        const deps = agentRuntimeDeps(&ctx);
        try deps.push_text(deps.ctx, .assistant_started);
        try deps.push_text(deps.ctx, .{ .assistant_source = "Completed commentary.\n\n" });
        try deps.push_text(deps.ctx, .assistant_started);
        try deps.push_text(deps.ctx, .{ .assistant_source = "Retained preview." });
        try deps.push_text(deps.ctx, .{ .assistant_restarted = "Restart\n" });
        try deps.push_text(deps.ctx, .{ .assistant_restarted = "Restart\n" });
        try deps.finalize_turn(deps.ctx, 1, outcome, null);
        try std.testing.expectEqualStrings(
            if (outcome == .completed) "Completed commentary.\n\n" else "Completed commentary.\n\nRetained preview.",
            ctx.assistant_output.items,
        );
        try std.testing.expectEqual(@as(usize, 0), ctx.final_output.items.len);
    }
}

test "CLI final output admits only completed assistant finish prompts" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer ctx.deinit();
    ctx.output_mode = .json;
    const deps = agentRuntimeDeps(&ctx);

    const cases = [_]types.FinishedPrompt{
        .{
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("prompt") },
                .assistant = @constCast("failed partial"),
            } },
            .terminal_outcome = .failed,
        },
        .{
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("prompt") },
                .assistant = @constCast("paused partial"),
            } },
            .terminal_outcome = .paused,
        },
        .{
            .turn = .{ .interrupted = .{
                .user = .{ .text = @constCast("prompt") },
                .assistant = @constCast("interrupted partial"),
            } },
            .terminal_outcome = .interrupted,
        },
        .{
            .turn = .{ .compacted_summary = .{
                .summary = @constCast("compacted partial"),
                .removed_turn_count = 1,
                .compaction_count = 1,
            } },
            .terminal_outcome = .completed,
        },
        .{
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("prompt") },
                .assistant = @constCast("unqualified partial"),
            } },
        },
    };

    for (cases) |source| {
        const owned = try types.dupeFinishedPrompt(std.heap.c_allocator, source);
        try deps.push_event(deps.ctx, .{ .finish_prompt = owned });
        try std.testing.expectEqual(@as(usize, 0), ctx.final_output.items.len);
        try std.testing.expectEqual(@as(usize, 0), ctx.final_source.items.len);
    }
}

test "CLI final source keeps only the completed response with its Markdown" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer ctx.deinit();
    ctx.output_mode = .json;
    const deps = agentRuntimeDeps(&ctx);

    const draft = "Add note probe\n\n## Summary\n\n- Uses **bold** and `inline code`.";
    try deps.push_text(deps.ctx, .assistant_started);
    try deps.push_text(deps.ctx, .{ .assistant_source = "Let me check the note first." });
    try deps.push_text(deps.ctx, .assistant_started);
    try deps.push_text(deps.ctx, .{ .assistant_source = draft });
    const finished = try types.dupeFinishedPrompt(std.heap.c_allocator, .{
        .turn = .{ .assistant = .{
            .user = .{ .text = @constCast("prompt") },
            .assistant = @constCast(draft),
        } },
        .terminal_outcome = .completed,
    });
    try deps.push_event(deps.ctx, .{ .finish_prompt = finished });

    const result = try takePromptRunResult(&ctx, alloc);
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, result.assistant_output, "Let me check the note first."));
    try std.testing.expectEqualStrings(draft, result.final_source);
    try std.testing.expectEqualStrings("Add note probe\n\n## Summary\n\n- Uses bold and inline code.", result.final_output);

    const displayed = try types.dupeFinishedPrompt(std.heap.c_allocator, .{
        .turn = .{ .assistant = .{
            .user = .{ .text = @constCast("prompt") },
            .assistant = @constCast(draft),
        } },
        .presentation_text = "Earlier candidate.\n\n" ++ draft,
        .terminal_outcome = .completed,
    });
    try deps.push_event(deps.ctx, .{ .finish_prompt = displayed });
    try std.testing.expectEqualStrings(draft, ctx.final_source.items);
    try std.testing.expect(std.mem.startsWith(u8, ctx.final_output.items, "Earlier candidate."));
}

test "CLI command output completion terminates only an open display line" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer ctx.deinit();
    ctx.output_mode = .json;

    try onCommandOutputChunk(&ctx, null, .stdout, "no-final");
    try pushCommandOutputComplete(&ctx, null);
    try std.testing.expectEqualStrings("no-final\n", stderr_capture.bytes.items);

    try onCommandOutputChunk(&ctx, null, .stdout, "with-final\n");
    try pushCommandOutputComplete(&ctx, null);
    try pushCommandOutputComplete(&ctx, null);
    try std.testing.expectEqualStrings(
        "no-final\nwith-final\n",
        stderr_capture.bytes.items,
    );
}

test "CLI nonterminal progress preserves distinct not-run labels without duplicates" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer ctx.deinit();
    ctx.output_mode = .raw;

    const deps = agentRuntimeDeps(&ctx);
    try deps.push_tool_lifecycle(deps.ctx, .{ .authoritative_started = .{
        .id = .{ .turn_id = 1, .call_id = "deferred_write" },
        .reconciles_provisional_call_id = null,
        .tool_name = "write_file",
        .activity_kind = .write,
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .progress = .{
        .id = .{ .turn_id = 1, .call_id = "deferred_write" },
        .text = "Writing file",
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .terminal = .{
        .id = .{ .turn_id = 1, .call_id = "deferred_write" },
        .outcome = .{ .kind = .deferred, .summary = "Reading project instructions before continuing: Writing file" },
    } });
    try std.testing.expectEqualStrings("Writing file\n", stderr_capture.bytes.items);

    try deps.push_tool_lifecycle(deps.ctx, .{ .authoritative_started = .{
        .id = .{ .turn_id = 2, .call_id = "retry_write" },
        .reconciles_provisional_call_id = null,
        .tool_name = "write_file",
        .activity_kind = .write,
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .progress = .{
        .id = .{ .turn_id = 2, .call_id = "retry_write" },
        .text = "Writing file",
    } });
    try std.testing.expectEqualStrings("Writing file\n", stderr_capture.bytes.items);
    try deps.push_tool_lifecycle(deps.ctx, .{ .terminal = .{
        .id = .{ .turn_id = 2, .call_id = "retry_write" },
        .outcome = .{ .kind = .deferred, .summary = "Reading project instructions before continuing: Writing file" },
    } });

    try deps.push_tool_lifecycle(deps.ctx, .{ .authoritative_started = .{
        .id = .{ .turn_id = 3, .call_id = "final_retry_write" },
        .reconciles_provisional_call_id = null,
        .tool_name = "write_file",
        .activity_kind = .write,
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .progress = .{
        .id = .{ .turn_id = 3, .call_id = "final_retry_write" },
        .text = "Writing file",
    } });
    try std.testing.expectEqualStrings("Writing file\n", stderr_capture.bytes.items);

    try deps.push_tool_lifecycle(deps.ctx, .{ .authoritative_started = .{
        .id = .{ .turn_id = 4, .call_id = "resolved_write" },
        .reconciles_provisional_call_id = null,
        .tool_name = "write_file",
        .activity_kind = .write,
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .progress = .{
        .id = .{ .turn_id = 4, .call_id = "resolved_write" },
        .text = "Writing build/pkg/proof.txt",
    } });
    try std.testing.expectEqualStrings(
        "Writing file\nWriting build/pkg/proof.txt\n",
        stderr_capture.bytes.items,
    );

    try deps.push_tool_lifecycle(deps.ctx, .{ .authoritative_started = .{
        .id = .{ .turn_id = 5, .call_id = "invalid_fetch" },
        .reconciles_provisional_call_id = null,
        .tool_name = "FetchURL",
        .activity_kind = .read,
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .progress = .{
        .id = .{ .turn_id = 5, .call_id = "invalid_fetch" },
        .text = "Fetching",
    } });
    try std.testing.expectEqualStrings(
        "Writing file\nWriting build/pkg/proof.txt\n",
        stderr_capture.bytes.items,
    );

    try deps.push_tool_lifecycle(deps.ctx, .{ .provisional = .{
        .id = .{ .turn_id = 6, .call_id = "streamed_read" },
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .progress = .{
        .id = .{ .turn_id = 6, .call_id = "streamed_read" },
        .text = "Reading streamed input",
    } });
    try std.testing.expectEqualStrings(
        "Writing file\nWriting build/pkg/proof.txt\nReading streamed input\n",
        stderr_capture.bytes.items,
    );

    try deps.push_tool_lifecycle(deps.ctx, .{ .authoritative_started = .{
        .id = .{ .turn_id = 7, .call_id = "legacy_deferred_write" },
        .reconciles_provisional_call_id = null,
        .tool_name = "write_file",
        .activity_kind = .write,
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .progress = .{
        .id = .{ .turn_id = 7, .call_id = "legacy_deferred_write" },
        .text = "Writing legacy file",
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .terminal = .{
        .id = .{ .turn_id = 7, .call_id = "legacy_deferred_write" },
        .outcome = .{ .kind = .denied, .summary = "Not executed: Writing legacy file" },
    } });
    try std.testing.expectEqualStrings(
        "Writing file\nWriting build/pkg/proof.txt\nReading streamed input\nWriting legacy file\n",
        stderr_capture.bytes.items,
    );

    try deps.push_tool_lifecycle(deps.ctx, .{ .authoritative_started = .{
        .id = .{ .turn_id = 8, .call_id = "legacy_retry_write" },
        .reconciles_provisional_call_id = null,
        .tool_name = "write_file",
        .activity_kind = .write,
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .progress = .{
        .id = .{ .turn_id = 8, .call_id = "legacy_retry_write" },
        .text = "Writing legacy file",
    } });
    try std.testing.expectEqualStrings(
        "Writing file\nWriting build/pkg/proof.txt\nReading streamed input\nWriting legacy file\n",
        stderr_capture.bytes.items,
    );
}

test "CLI output mode selection preserves machine output precedence" {
    try std.testing.expectEqual(OutputMode.json, selectOutputMode(true, true, true, true));
    try std.testing.expectEqual(OutputMode.quiet, selectOutputMode(true, false, true, false));
    try std.testing.expectEqual(OutputMode.raw, selectOutputMode(false, false, false, true));
    try std.testing.expectEqual(OutputMode.terminal, selectOutputMode(false, false, true, false));
    try std.testing.expectEqual(OutputMode.terminal_no_color, selectOutputMode(false, false, true, true));
}
