const std = @import("std");
const observation = @import("observation.zig");
const cache_warmer = @import("cache_warmer.zig");
const skill_contract = @import("../../skills/skill_contract.zig");
const agent_stream_provider = @import("../stream_provider.zig");
const auth_runtime = @import("../../auth/auth_runtime.zig");
const session_codec = @import("../../session/session_codec.zig");
const command_admission = @import("../../permissions/command_admission.zig");
const permission_auto_classifier = @import("../../permissions/auto_classifier.zig");
const model_capabilities = @import("../../config/model_capabilities.zig");
const model_catalog = @import("../../gateway/model_catalog.zig");
const types = @import("../../shared/types.zig");
const worker_runtime = @import("../worker_runtime.zig");
const file_mutation = @import("../../tooling/file_mutation.zig");
const tool_admission = @import("../../tooling/tool_admission.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const tool_contracts = @import("tool_contracts.zig");
const context_contract = @import("../../workspace/context_contract.zig");
const compaction_activity = @import("../../output/compaction_activity.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolCall = types.ToolCall;
const WorkerEvent = worker_runtime.WorkerEvent;

const DeferredToolCompletion = tool_contracts.DeferredToolCompletion;
const DiffEntryPayload = tool_contracts.DiffEntryPayload;
const ToolCallValidationResult = tool_contracts.ToolCallValidationResult;
const ToolExecutionRequest = tool_contracts.ToolExecutionRequest;
const ToolExecutionResult = tool_contracts.ToolExecutionResult;
const TransportPublicationOutcome = tool_contracts.TransportPublicationOutcome;
pub const LiveToolAuthority = tool_contracts.LiveToolAuthority;

pub const TurnProgress = struct {
    user: types.UserTurn,
    execution: types.ExecutionMemory,
    running_calls: []const types.ToolCall = &.{},
    running_assistant: ?[]const u8 = null,
    recovery_record: types.RecoveryRecordWrite = .keep,
};

pub const RecoveryCheckpointEffect = struct {
    set: *const fn (ctx: *anyopaque, checkpoint: session_codec.RecoveryCheckpoint) anyerror!void,
    clear: *const fn (ctx: *anyopaque) anyerror!void,
};

pub const CompactionActivityEffect = struct {
    begin: *const fn (ctx: *anyopaque, origin: compaction_activity.Origin, turn_id: ?u64) compaction_activity.OperationId,
    running: *const fn (ctx: *anyopaque, id: compaction_activity.OperationId, stage: compaction_activity.Stage) void,
    settle: *const fn (ctx: *anyopaque, id: compaction_activity.OperationId, feedback: compaction_activity.Feedback) void,
};

pub const ContextCompactionCommitEffect = struct {
    commit: *const fn (
        ctx: *anyopaque,
        summary: types.CompactedSummaryHistoryTurn,
        active_prefix: ?types.AssistantHistoryTurn,
        retained_from: ?types.ContextHistoryCut,
    ) anyerror!void,
};

pub const LiveToolAuthorityDecision = enum {
    allow,
    ask,
    deny,
    unavailable,
};

pub const ResolvedLiveToolAuthority = struct {
    authority: LiveToolAuthority,
    decision: LiveToolAuthorityDecision,
};

pub const LiveToolAuthorityProvider = struct {
    context: *anyopaque,
    resolve_fn: *const fn (
        *anyopaque,
        Allocator,
        ToolCall,
        []const u8,
        []const u8,
        tool_dispatch.PermissionTargetKind,
    ) anyerror!ResolvedLiveToolAuthority,

    pub fn resolve(
        self: LiveToolAuthorityProvider,
        alloc: Allocator,
        call: ToolCall,
        workspace_root: []const u8,
        target: []const u8,
        target_kind: tool_dispatch.PermissionTargetKind,
    ) !ResolvedLiveToolAuthority {
        return self.resolve_fn(
            self.context,
            alloc,
            call,
            workspace_root,
            target,
            target_kind,
        );
    }
};

pub const ToolActivityPhase = enum { started, succeeded, failed, denied };

pub const ToolActivityRecorder = struct {
    context: *anyopaque,
    record_fn: *const fn (
        *anyopaque,
        []const u8,
        []const u8,
        ToolActivityPhase,
    ) anyerror!void,

    pub fn record(
        self: ToolActivityRecorder,
        call_id: []const u8,
        tool_name: []const u8,
        phase: ToolActivityPhase,
    ) !void {
        return self.record_fn(self.context, call_id, tool_name, phase);
    }
};

fn acknowledgePromptFinalization(_: *anyopaque, _: u64, _: types.TurnPresentationOutcome, _: ?types.ProviderCompletionDisposition) !void {}
fn discardToolLifecycle(_: *anyopaque, _: types.ToolLifecycleEvent) !void {}
fn discardRouteRecoveryStatus(_: *anyopaque, _: types.RouteRecoveryStatus) !void {}
fn localAvailableModelCapabilities(_: *anyopaque, model: []const u8) model_capabilities.Capabilities {
    return model_capabilities.capabilitiesForModel(model);
}
fn localModelCapabilities(_: *anyopaque, _: Allocator, model: []const u8) !model_capabilities.Capabilities {
    return model_capabilities.capabilitiesForModel(model);
}

pub const OutOfCreditsChoice = enum {
    retry,
    switch_model,
    cancel,
};

pub const CredentialRefreshMode = auth_runtime.CredentialRefreshMode;

pub const TextEmission = union(enum) {
    assistant_started,
    assistant_source: []const u8,
    assistant_rendered: []const u8,
    assistant_restarted: []const u8,
    operational: []const u8,
};

pub const DiffMarkerStyles = struct {
    added: []const u8 = "",
    removed: []const u8 = "",
};

pub const PermissionObserver = struct {
    ctx: *anyopaque,
    request: *const fn (ctx: *anyopaque, turn_id: u64, call: types.ToolCall) void,
    result: *const fn (ctx: *anyopaque, turn_id: u64, call: types.ToolCall, decision: types.ToolPermissionDecision) void,
};

pub const AgentRuntimeDeps = struct {
    ctx: *anyopaque,
    observer: ?*observation.Observer = null,
    permission_observer: ?PermissionObserver = null,
    agent_stream_provider: agent_stream_provider.Provider = agent_stream_provider.unavailable_provider,
    flush_assistant_stream_per_content_chunk: bool = false,
    render_assistant_text: bool = true,
    cooperative_transport_pulse: ?agent_stream_provider.CooperativePulse = null,
    tool_registry: tool_dispatch.Registry = .{},
    context_registry: ?context_contract.Registry = null,
    context_enabled: bool = false,
    live_tool_authority: ?LiveToolAuthorityProvider = null,
    snapshot_root_permission_mode: ?*const fn (ctx: *anyopaque) PermissionMode = null,
    tool_activity_recorder: ?ToolActivityRecorder = null,
    finalize_turn: *const fn (ctx: *anyopaque, turn_id: u64, outcome: types.TurnPresentationOutcome, disposition: ?types.ProviderCompletionDisposition) anyerror!void = acknowledgePromptFinalization,
    take_steering_boundary: ?*const fn (
        ctx: *anyopaque,
        arena: Allocator,
        turn_id: u64,
        kind: worker_runtime.SteeringBoundaryKind,
    ) anyerror!worker_runtime.SteeringBoundaryResult = null,
    release_agent_terminal_lease: *const fn (ctx: *anyopaque, session_id: []const u8) anyerror!void = terminalLeaseCleanupUnavailable,
    append_runtime_context: *const fn (ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) anyerror!void,
    append_static_context: ?*const fn (ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) anyerror!void = null,
    validate_tool_call: ?*const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall) anyerror!ToolCallValidationResult = null,
    snapshot_mcp_definition: ?*const fn (*anyopaque, Allocator, []const u8, types.McpToolBinding) anyerror!@import("../../tooling/tool_mcp_runtime.zig").DefinitionSnapshot = null,
    resolve_unselected_mcp_tool: ?*const fn (ctx: *anyopaque, arena: Allocator, name: []const u8) anyerror!?@import("../../tooling/tool_mcp_runtime.zig").SelectedTool = null,
    prepare_skill_call: ?*const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall, locations: ?*const skill_contract.Locations) anyerror!skill_contract.CallPreparation = null,
    check_tool_availability: ?*const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall) anyerror!?[]const u8 = null,
    request_tool_permission: *const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?LiveToolAuthority, revalidation: ?tool_contracts.LivePermissionRevalidation, advertised_dynamic_tool_names: []const []const u8, mcp_review_schema_json: ?[]const u8) anyerror!command_admission.PermissionOutcome,
    request_prepared_file_mutation_permission: ?*const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?LiveToolAuthority, advertised_dynamic_tool_names: []const []const u8) anyerror!command_admission.PermissionOutcome = null,
    resolve_tool_action_display_target: ?*const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall) anyerror!?[]const u8 = null,
    describe_tool_action: *const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) anyerror![]const u8,
    describe_tool_action_completed: *const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) anyerror![]const u8,
    describe_tool_action_denied: *const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8, advertised_dynamic_tool_names: []const []const u8) anyerror![]const u8,
    subagent_status_renderer: ?types.SubagentStatusRenderer = null,
    permission_target_for_call: *const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) anyerror![]const u8,
    execute_tool_call: *const fn (ctx: *anyopaque, request: ToolExecutionRequest) anyerror!ToolExecutionResult,
    publish_committed_file_handoff: *const fn (ctx: *anyopaque, handoff: file_mutation.CommittedFileHandoff) tool_contracts.SecondaryPublicationReport,
    publish_deferred_tool_completion: ?*const fn (ctx: *anyopaque, completion: DeferredToolCompletion) TransportPublicationOutcome = null,
    propagate_history_turn: *const fn (ctx: *anyopaque, turn: HistoryTurn) anyerror!void,
    commit_context_compaction: ?ContextCompactionCommitEffect = null,
    compaction_activity: ?CompactionActivityEffect = null,
    compaction_failure: ?*?compaction_activity.ErrorProvenance = null,
    recovery_checkpoint: ?RecoveryCheckpointEffect = null,
    append_turn_piece: ?*const fn (ctx: *anyopaque, progress: TurnProgress) anyerror!void = null,
    save_recovery_record: ?*const fn (ctx: *anyopaque, record: types.RecoveryRecordWrite) anyerror!bool = null,
    record_usage: ?*const fn (ctx: *anyopaque, usage: types.Usage) anyerror!void = null,
    save_todos: ?*const fn (ctx: *anyopaque, json: []const u8) anyerror!void = null,
    cache_warmer: ?*cache_warmer.Warmer = null,
    save_prompt_images: ?*const fn (ctx: *anyopaque, alloc: Allocator, images: []types.ImageAttachment) anyerror!void = null,
    confirm_session_writer: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    propagate_grant: *const fn (ctx: *anyopaque, tool_name: []const u8, target_path: []const u8) anyerror!void,
    push_event: *const fn (ctx: *anyopaque, event: WorkerEvent) anyerror!void,
    push_text: *const fn (ctx: *anyopaque, emission: TextEmission) anyerror!void,
    push_reasoning_delta: ?*const fn (ctx: *anyopaque, delta: []const u8) anyerror!void = null,
    push_tool_lifecycle: *const fn (ctx: *anyopaque, event: types.ToolLifecycleEvent) anyerror!void = discardToolLifecycle,
    push_diff_block: *const fn (ctx: *anyopaque, payload: DiffEntryPayload) anyerror!void,
    push_system_notice: *const fn (ctx: *anyopaque, text: []const u8) anyerror!void,
    push_interactive_notice: ?*const fn (ctx: *anyopaque, notice: types.SemanticNotice) anyerror!void = null,
    push_context_notice: ?*const fn (ctx: *anyopaque, text: []const u8) anyerror!void = null,
    push_route_recovery_status: *const fn (ctx: *anyopaque, status: types.RouteRecoveryStatus) anyerror!void = discardRouteRecoveryStatus,
    begin_route_recovery_request: ?*const fn (ctx: *anyopaque) void = null,
    restore_failed_prompt: ?*const fn (ctx: *anyopaque, prompt: []const u8) anyerror!void = null,
    push_command_output_complete: *const fn (ctx: *anyopaque, lifecycle_id: ?types.ToolLifecycleId) anyerror!void,
    push_http_error: *const fn (ctx: *anyopaque, status: std.http.Status, detail: []const u8, credential_source: ?types.CredentialSource) anyerror!void,
    refresh_gateway_credential: ?*const fn (ctx: *anyopaque, alloc: Allocator, source: types.CredentialSource, mode: CredentialRefreshMode, expected_account_id: ?[]const u8) anyerror!?[]u8 = null,
    ask_out_of_credits: ?*const fn (ctx: *anyopaque) anyerror!OutOfCreditsChoice = null,
    available_model_capabilities: *const fn (ctx: *anyopaque, model: []const u8) model_capabilities.Capabilities = localAvailableModelCapabilities,
    resolve_model_capabilities: *const fn (ctx: *anyopaque, arena: Allocator, model: []const u8) anyerror!model_capabilities.Capabilities = localModelCapabilities,
    model_catalog_failure: ?*const fn (ctx: *anyopaque) ?model_catalog.FailureCategory = null,
    format_tool_execution_error: *const fn (ctx: *anyopaque, arena: Allocator, tool_name: []const u8, err: anyerror) anyerror![]const u8,
    record_tool_call_rejected: ?*const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall, model_output: []const u8, command_result_json: ?[]const u8) anyerror!void = null,
    record_tool_call_failed: ?*const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall, model_output: []const u8, command_result_json: ?[]const u8) anyerror!void = null,
    report_usage: ?*const fn (ctx: *anyopaque, usage: types.Usage) void = null,
    report_inner_tool_usage: ?*const fn (ctx: *anyopaque, tool_name: []const u8, usage: types.ToolUsage) void = null,

    diff_marker_styles: DiffMarkerStyles = .{},

    pub fn pushContextNotice(self: *const AgentRuntimeDeps, text: []const u8) !void {
        if (self.push_context_notice) |push| return push(self.ctx, text);
        return self.push_system_notice(self.ctx, text);
    }

    pub fn executeToolCall(self: *const AgentRuntimeDeps, request: ToolExecutionRequest) !ToolExecutionResult {
        if (self.observer) |observer| observer.emit(.{ .tool_start = .{ .call = request.call } });
        var observed_request = request;
        observed_request.observer = self.observer orelse request.observer;
        const result = self.execute_tool_call(self.ctx, observed_request) catch |err| {
            if (self.observer) |observer| observer.emit(.{ .tool_end = .{
                .call = request.call,
                .status = if (err == error.Cancelled) "cancelled" else "failure",
                .error_name = @errorName(err),
            } });
            return err;
        };
        if (self.observer) |observer| observer.emit(.{ .tool_end = .{
            .call = request.call,
            .output = result.model_output,
            .status = if (result.cancelled) "cancelled" else @tagName(result.status),
            .usage = result.inner_usage,
        } });
        return result;
    }
};

fn terminalLeaseCleanupUnavailable(_: *anyopaque, _: []const u8) !void {
    return error.TerminalLeaseCleanupUnavailable;
}
