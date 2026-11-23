const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const vision_contracts = @import("../agent/runtime/vision_contracts.zig");
const command_admission = @import("../permissions/command_admission.zig");
const shell_snapshot = @import("../terminal/shell_snapshot.zig");
const command_environment = @import("../execution/command_environment.zig");
const file_mutation = @import("file_mutation.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const image_attachments = @import("../images/image_attachments.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const diff_mod = @import("../output/diff.zig");
const pathing = @import("../workspace/pathing.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const plan_mode = @import("../permissions/plan_mode.zig");
const start_permission = @import("../permissions/start_permission.zig");
const sensitive_file = @import("../permissions/sensitive_file.zig");
const terminal_contracts = @import("../terminal/contracts.zig");
const terminal_managed_observer = @import("../terminal/managed_observer.zig");
const permission_prompter = @import("../permissions/permission_prompter.zig");
const permission_request = @import("../permissions/permission_request.zig");
const permissions = @import("../permissions/permissions.zig");
const shell_resolver = @import("../terminal/shell_resolver.zig");
const tool_args = @import("tool_args.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_mcp_runtime = @import("tool_mcp_runtime.zig");
const tool_presentation = @import("tool_presentation.zig");
const test_builtin_tools = if (builtin.is_test)
    @import("../../builtins/tools.zig")
else
    struct {};
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const context_limits = @import("../config/context_limits.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const current_branch = @import("../workspace/current_branch.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolPermissionDecision = types.ToolPermissionDecision;
const WorkerRuntime = worker_runtime.WorkerRuntime;

pub const HostSandboxDefault = enum {
    none,
    allow_sandboxed,
    prompt,
};

pub const SessionPermissionStateProvider = struct {
    context: *anyopaque,
    snapshot_fn: *const fn (
        context: *anyopaque,
        alloc: Allocator,
    ) anyerror!session_permission_state.State,

    pub fn snapshot(
        self: SessionPermissionStateProvider,
        alloc: Allocator,
    ) !session_permission_state.State {
        return self.snapshot_fn(self.context, alloc);
    }
};

pub const PlanSaver = struct {
    context: *anyopaque,
    save_fn: *const fn (
        context: *anyopaque,
        arena: Allocator,
        text: []const u8,
    ) anyerror![]const u8,

    pub fn save(self: PlanSaver, arena: Allocator, text: []const u8) ![]const u8 {
        return self.save_fn(self.context, arena, text);
    }
};

pub const Input = struct {
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
    permission_review_turn: ?permission_auto_classifier.ReviewTurnContext = null,
    permission_grants: []const PermissionGrant,
    permission_rules: types.PermissionRuleSet,
    session_permission_state: ?*const session_permission_state.State = null,
    session_permission_state_provider: ?SessionPermissionStateProvider = null,
    plan_mode: ?*plan_mode.State = null,
    plan_saver: ?PlanSaver = null,
    tool_registry: tool_dispatch.Registry,
    worker: *WorkerRuntime,
    mcp_review_schema_json: ?[]const u8 = null,
    permission_prompter: ?permission_prompter.Prompter = null,
    advertised_dynamic_tool_names: []const []const u8,
    mcp_runtime: tool_mcp_runtime.RuntimeCapabilities,
    context_limits: context_limits.Values = .{},
    auto_classifier: permission_auto_classifier.Classifier = .disabled(),
    terminal_review_context: ?terminal_managed_observer.Context = null,
    host_sandbox_default: HostSandboxDefault = .none,
    sensitive_file_guard: bool = true,
    workspace_in_git_work_tree: bool = false,
    dangerous_command_ask_answered: bool = false,
};

fn registeredTool(input: anytype, name: []const u8) ?*const tool_dispatch.Tool {
    return input.tool_registry.lookup(name);
}

fn accessScope(input: Input) workspace_access.AccessScope {
    return input.access_scope orelse workspace_access.AccessScope.primaryOnly(input.workspace_root);
}

fn permissionTargetKind(registry: tool_dispatch.Registry, name: []const u8) permissions.PermissionTargetKind {
    return if (registry.lookup(name)) |tool| tool.permission_target_kind else .none;
}

fn toolHasPermissionContract(input: Input, name: []const u8) bool {
    return registeredTool(input, name) != null;
}

fn toolRequiresApproval(input: anytype, name: []const u8) bool {
    return if (registeredTool(input, name)) |spec| spec.requires_approval else false;
}

fn toolApprovalPolicy(input: anytype, name: []const u8) tool_dispatch.ApprovalPolicy {
    return if (registeredTool(input, name)) |spec| spec.approval_policy else .standard;
}

fn hostToolNeedsAskApproval(input: anytype, call: ToolCall, permission_mode: PermissionMode) bool {
    return toolRequiresApproval(input, call.name) and (permission_mode == .ask or permission_mode == .dontAsk);
}

pub fn callUsesCommandAuthority(
    registry: tool_dispatch.Registry,
    arena: Allocator,
    call: ToolCall,
) !bool {
    const tool = registry.lookup(call.name) orelse return false;
    if (tool.executor_kind == .run_command) return true;
    if (tool.captured_command_implicit) return true;
    const expected_action = tool.captured_command_action orelse return false;
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const action = tool_args.optionalStringArg(args, "action") orelse return false;
    return std.mem.eql(u8, action, expected_action);
}

fn isRunCommandCall(input: anytype, arena: Allocator, call: ToolCall) !bool {
    return callUsesCommandAuthority(input.tool_registry, arena, call);
}

fn permissionNameForCall(input: Input, arena: Allocator, call: ToolCall) ![]const u8 {
    const command_call = try isRunCommandCall(input, arena, call);
    if (command_call) return "run_command";
    return if (std.mem.eql(u8, call.name, "Bash")) "terminal" else call.name;
}

fn permissionTargetKindForCall(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) !permissions.PermissionTargetKind {
    return if (try isRunCommandCall(input, arena, call))
        .command_cwd
    else
        permissionTargetKind(input.tool_registry, call.name);
}

fn registeredWebSearchTarget(input: Input, name: []const u8) ?[]const u8 {
    const spec = registeredTool(input, name) orelse return null;
    if (spec.executor_kind != .web_search) return null;
    return spec.name;
}

pub const FileMutationPreflight = union(enum) {
    allowed: file_mutation_contract.FileExecutionAuthorization,
    prompt: file_mutation_contract.FileExecutionAuthorization,
    permission_required: file_mutation_contract.FileExecutionAuthorization,
    policy_denied,
    tool_failure: []const u8,
};

pub const FileMutationPreflightRequest = struct {
    tool_registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
    permission_rules: types.PermissionRuleSet,
    session_grants: []const PermissionGrant = &.{},
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant = &.{},
    can_prompt: bool,
    session_permission_state: ?*const session_permission_state.State = null,
    prepare_permission_identity: bool = false,
    sensitive_file_guard: bool = false,
};

pub const FileMutationPreparationRequest = struct {
    tool_registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
};

pub const PreparedFileMutationCall = struct {
    call_id: []u8,
    arguments_hash: types.ContentHash,
    workspace_root: []u8,
    input: file_mutation_contract.FileMutationInput,
    targets: file_mutation_contract.ResolvedFileMutationTargets,
    workspace_root_owned: bool = true,
    call_id_owned: bool = true,
    input_owned: bool = true,

    pub fn targetPath(self: PreparedFileMutationCall) []const u8 {
        return self.targets.canonical_target_path;
    }

    pub fn externalActionIdentity(
        self: PreparedFileMutationCall,
    ) ?FileMutationActionIdentity {
        if (self.targets.anchor.scope != .external) return null;
        return FileMutationActionIdentity.init(
            self.targets.canonical_target_path,
            self.input,
        );
    }

    pub fn deinit(self: *PreparedFileMutationCall, alloc: Allocator) void {
        if (self.input_owned) {
            self.input.deinit(alloc);
            self.input_owned = false;
        }
        self.targets.deinit(alloc);
        if (self.call_id_owned) {
            alloc.free(self.call_id);
            self.call_id_owned = false;
        }
        if (self.workspace_root_owned) {
            alloc.free(self.workspace_root);
            self.workspace_root_owned = false;
        }
    }

    fn takeInput(self: *PreparedFileMutationCall) file_mutation_contract.FileMutationInput {
        std.debug.assert(self.input_owned);
        self.input_owned = false;
        return self.input;
    }

    fn takeTargets(self: *PreparedFileMutationCall) file_mutation_contract.ResolvedFileMutationTargets {
        std.debug.assert(self.targets.owns_memory);
        const targets = self.targets;
        self.targets.relinquish();
        return targets;
    }
};

pub const FileMutationActionIdentity = struct {
    kind: file_mutation_contract.Kind,
    target_hash: types.ContentHash,
    first_argument_hash: types.ContentHash,
    second_argument_hash: types.ContentHash,
    replace_all: bool = false,

    fn init(
        canonical_target_path: []const u8,
        input: file_mutation_contract.FileMutationInput,
    ) FileMutationActionIdentity {
        var identity: FileMutationActionIdentity = .{
            .kind = std.meta.activeTag(input),
            .target_hash = hashIdentityField(canonical_target_path),
            .first_argument_hash = undefined,
            .second_argument_hash = undefined,
        };
        switch (input) {
            .write => |write| {
                identity.first_argument_hash = hashIdentityField(write.content);
                identity.second_argument_hash = hashIdentityField(@tagName(write.mode));
            },
            .edit => |edit| {
                identity.first_argument_hash = hashIdentityField(edit.old_string);
                identity.second_argument_hash = hashIdentityField(edit.new_string);
                identity.replace_all = edit.replace_all;
            },
        }
        return identity;
    }

    pub fn eql(
        a: FileMutationActionIdentity,
        b: FileMutationActionIdentity,
    ) bool {
        return std.meta.eql(a, b);
    }
};

fn hashIdentityField(value: []const u8) types.ContentHash {
    var digest: types.ContentHash = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    return digest;
}

pub const FileMutationPreparation = union(enum) {
    prepared: PreparedFileMutationCall,
    tool_failure: []const u8,
    not_file_mutation,
};

const FileMutationDecodeResult = union(enum) {
    input: file_mutation_contract.FileMutationInput,
    failure: []const u8,
    not_file_mutation,
};

var file_mutation_decode_count: usize = 0;
var file_mutation_resolution_count: usize = 0;

fn decodeFileMutationInput(
    arena: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) !FileMutationDecodeResult {
    const tool = registry.lookup(call.name) orelse return .{
        .failure = try arena.dupe(
            u8,
            "file mutation tool is not registered",
        ),
    };
    const kind: file_mutation_contract.Kind = switch (tool.executor_kind) {
        .write_file => .write,
        .edit_file => .edit,

        .host => return .not_file_mutation,
        else => return .{ .failure = try arena.dupe(
            u8,
            "unsupported file mutation tool",
        ) },
    };
    const take_input = tool.take_file_mutation_input_fn orelse return .{
        .failure = try arena.dupe(
            u8,
            "file mutation tool registration is missing canonical input ownership",
        ),
    };

    if (builtin.is_test) file_mutation_decode_count += 1;
    const decode_ctx = tool_dispatch.DispatchContext{ .allocator = arena };
    const decoded = try tool.decode(decode_ctx, call.arguments_json);
    return switch (decoded) {
        .failure => |reason| .{ .failure = reason },
        .input => |tool_input| blk: {
            var tool_input_owned = true;
            defer if (tool_input_owned) tool_input.deinit(arena);
            if (tool.validate) |validate| {
                if (try validate(decode_ctx, tool_input)) |reason| {
                    break :blk .{ .failure = reason };
                }
            }
            var input = take_input(tool_input, arena);
            tool_input_owned = false;
            if (std.meta.activeTag(input) != kind) {
                input.deinit(arena);
                break :blk .{ .failure = try arena.dupe(
                    u8,
                    "file mutation tool registration returned mismatched input kind",
                ) };
            }
            break :blk .{ .input = input };
        },
    };
}

pub fn prepareFileMutationCall(
    alloc: Allocator,
    call: ToolCall,
    request: FileMutationPreparationRequest,
) !FileMutationPreparation {
    var input = switch (try decodeFileMutationInput(
        alloc,
        request.tool_registry,
        call,
    )) {
        .failure => |reason| return .{ .tool_failure = reason },
        .not_file_mutation => return .not_file_mutation,
        .input => |value| value,
    };
    var input_owned = true;
    defer if (input_owned) input.deinit(alloc);

    if (builtin.is_test) file_mutation_resolution_count += 1;
    var targets = switch (try permissions.prepareFileMutationTargets(
        alloc,
        request.workspace_root,
        input,
    )) {
        .target_resolution_failure => |failure| return .{ .tool_failure = try alloc.print(
            "file mutation target resolution failed: {s}",
            .{@tagName(failure)},
        ) },
        .prepared => |value| value,
    };
    errdefer targets.deinit(alloc);

    const workspace_root = try alloc.dupe(u8, request.workspace_root);
    errdefer alloc.free(workspace_root);
    const call_id = try alloc.dupe(u8, call.id);
    var arguments_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    arguments_hasher.update(call.arguments_json);
    input_owned = false;
    return .{ .prepared = .{
        .call_id = call_id,
        .arguments_hash = arguments_hasher.finalResult(),
        .workspace_root = workspace_root,
        .input = input,
        .targets = targets,
    } };
}

pub fn preflightPreparedFileMutation(
    arena: Allocator,
    call: ToolCall,
    prepared: *PreparedFileMutationCall,
    request: FileMutationPreflightRequest,
) !FileMutationPreflight {
    defer prepared.deinit(arena);

    const expected_kind: file_mutation_contract.Kind =
        if (std.mem.eql(u8, call.name, "write_file"))
            .write
        else if (std.mem.eql(u8, call.name, "edit_file"))
            .edit
        else
            return .{ .tool_failure = "prepared file mutation no longer matches tool call" };
    if (std.meta.activeTag(prepared.input) != expected_kind or
        !std.mem.eql(u8, prepared.call_id, call.id) or
        !std.mem.eql(u8, prepared.workspace_root, request.workspace_root))
    {
        return .{ .tool_failure = "prepared file mutation no longer matches tool call" };
    }
    var arguments_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    arguments_hasher.update(call.arguments_json);
    if (!std.mem.eql(u8, &prepared.arguments_hash, &arguments_hasher.finalResult())) {
        return .{ .tool_failure = "prepared file mutation no longer matches tool call" };
    }

    var input = prepared.takeInput();
    var input_owned = true;
    defer if (input_owned) input.deinit(arena);
    var targets = prepared.takeTargets();

    const policy_result = try permissions.evaluatePreparedFileMutationTargetsInScope(
        arena,
        request.access_scope orelse workspace_access.AccessScope.primaryOnly(request.workspace_root),
        expected_kind,
        &targets,
        request.permission_mode,
        request.permission_rules,
        request.session_grants,
        request.local_grants,
    );
    var policy_targets = switch (policy_result) {
        .target_resolution_failure => |failure| {
            return .{ .tool_failure = try arena.print(
                "file mutation target resolution failed: {s}",
                .{@tagName(failure)},
            ) };
        },
        .policy_denied => return .policy_denied,
        .evaluated => |evaluated| evaluated,
    };
    var policy_targets_owned = true;
    defer if (policy_targets_owned) policy_targets.deinitOwned(arena);

    const guarded_path_prompt_required = request.sensitive_file_guard and
        request.permission_mode != .auto and
        fileMutationTargetsContainGuardedPathAsk(policy_targets);
    const edit_prompt_required = policy_targets.prompt_required or guarded_path_prompt_required;
    const equality_prompt_required =
        request.permission_mode != .auto and
        policy_targets.items[0].expected_identity != null and
        try fileMutationEqualityDisclosureRequiresPrompt(
            arena,
            request,
            policy_targets.canonical_target_path,
        );

    var authorization: file_mutation_contract.FileExecutionAuthorization = .{
        .input = input,
        .policy_targets = policy_targets,
        .read_disclosure_required = equality_prompt_required,
    };
    const state_may_decide = if (request.session_permission_state) |state|
        state.rules.items.len > 0
    else
        false;
    if (!edit_prompt_required and
        !equality_prompt_required and
        !state_may_decide and
        !request.prepare_permission_identity)
    {
        input_owned = false;
        policy_targets_owned = false;
        return .{ .allowed = authorization };
    }
    if (!request.can_prompt and edit_prompt_required and equality_prompt_required) {
        input_owned = false;
        policy_targets_owned = false;
        return .{ .permission_required = authorization };
    }

    authorization.prepared = switch (try file_mutation.prepareResolvedTarget(
        arena,
        call,
        input,
        policy_targets,
    )) {
        .semantic_failure => |reason| return .{ .tool_failure = reason },
        .prepared => |value| value,
    };
    if (request.session_permission_state) |state| {
        const key = permissionStateKeyForPreparedFileMutation(
            arena,
            authorization.prepared.?,
        ) catch null;
        if (key) |resolved_key| switch (session_permission_state.decide(state.*, resolved_key)) {
            .deny => return .policy_denied,
            .allow => {
                input_owned = false;
                policy_targets_owned = false;
                return .{ .allowed = authorization };
            },
            .unresolved => {},
        };
    }
    const prompt_required = if (file_mutation_contract.preparedMutationIsNoop(
        authorization.prepared.?,
    ))
        equality_prompt_required
    else
        edit_prompt_required;
    if (!prompt_required or request.prepare_permission_identity) {
        input_owned = false;
        policy_targets_owned = false;
        return .{ .allowed = authorization };
    }
    authorization.approval_intent = if (file_mutation_contract.preparedMutationIsNoop(
        authorization.prepared.?,
    ))
        .equality_disclosure
    else
        .mutation;
    if (!request.can_prompt) {
        input_owned = false;
        policy_targets_owned = false;
        return .{ .permission_required = authorization };
    }
    authorization.grant_offer = permissions.structuredFileGrantOffer(
        arena,
        request.workspace_root,
        call.name,
        policy_targets,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedFileGrantOffer,
        error.ScopeProjectionTooLarge,
        => return .{ .tool_failure = "file mutation permission scope could not be represented safely" },
    };
    input_owned = false;
    policy_targets_owned = false;
    return .{ .prompt = authorization };
}

pub fn preflightFileMutation(
    arena: Allocator,
    call: ToolCall,
    request: FileMutationPreflightRequest,
) !FileMutationPreflight {
    var prepared = switch (try prepareFileMutationCall(arena, call, .{
        .tool_registry = request.tool_registry,
        .workspace_root = request.workspace_root,
    })) {
        .tool_failure => |reason| return .{ .tool_failure = reason },

        .not_file_mutation => return .{ .tool_failure = "file mutation preflight is unavailable for host tools" },
        .prepared => |value| value,
    };
    defer prepared.deinit(arena);
    return preflightPreparedFileMutation(arena, call, &prepared, request);
}

fn fileMutationEqualityDisclosureRequiresPrompt(
    arena: Allocator,
    request: FileMutationPreflightRequest,
    target_path: []const u8,
) !bool {
    return switch (try permissions.ruleDecisionFor(
        arena,
        request.permission_rules,
        request.workspace_root,
        "read_file",
        target_path,
        permissionTargetKind(request.tool_registry, "read_file"),
    )) {
        .allow, .none => false,
        .deny => true,
        .ask => !permissions.sessionGrantAllowed(
            request.session_grants,
            "read_file",
            target_path,
        ) and !permissions.sessionGrantAllowed(
            request.local_grants,
            "read_file",
            target_path,
        ),
    };
}

const FileMutationAdmission = union(enum) {
    resolved: command_admission.PermissionOutcome,
    prompt: struct {
        authorization: file_mutation_contract.FileExecutionAuthorization,
    },
};

fn fileMutationTargetsContainConfiguredAsk(
    targets: file_mutation_contract.PolicyEvaluatedFileTargets,
) bool {
    for (targets.items) |target| {
        if (target.rule == .ask and !target.session_grant_allowed) return true;
    }
    return false;
}

fn fileMutationTargetsContainGuardedPathAsk(
    targets: file_mutation_contract.PolicyEvaluatedFileTargets,
) bool {
    const path = targets.canonical_target_path;
    if (!sensitive_file.isSensitiveFile(path) and !sensitive_file.isGitControlPath(path)) return false;
    for (targets.items) |target| {
        if (target.path_end != targets.canonical_target_path.len) continue;
        if (target.rule == .allow or target.session_grant_allowed) return false;
    }
    return true;
}

fn fileMutationAuthorizationNeedsNoPrompt(
    permission_mode: PermissionMode,
    sensitive_file_guard: bool,
    git_write_scope: ?workspace_access.AccessScope,
    authorization: file_mutation_contract.FileExecutionAuthorization,
) bool {
    const asks_when_needed = authorization.read_disclosure_required or
        fileMutationTargetsContainConfiguredAsk(authorization.policy_targets) or
        (sensitive_file_guard and fileMutationTargetsContainGuardedPathAsk(authorization.policy_targets));
    return switch (permission_mode) {
        .ask, .dontAsk => !asks_when_needed and
            fileMutationTargetInsideGitWorkTreeScope(git_write_scope, authorization.policy_targets),
        .auto => true,
        .yolo => !asks_when_needed,
    };
}

fn fileMutationTargetInsideGitWorkTreeScope(
    git_write_scope: ?workspace_access.AccessScope,
    targets: file_mutation_contract.PolicyEvaluatedFileTargets,
) bool {
    const scope = git_write_scope orelse return false;
    return scope.contains(targets.canonical_target_path);
}

fn gitWorkTreeWriteScope(input: Input) ?workspace_access.AccessScope {
    return if (input.workspace_in_git_work_tree) accessScope(input) else null;
}

fn isPathTargetKind(kind: permissions.PermissionTargetKind) bool {
    return switch (kind) {
        .path_existing, .path_optional_existing, .path_create_parent, .path_existing_parent => true,
        .none, .command_cwd, .url => false,
    };
}

fn resolveOrdinaryPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    is_dynamic_tool: bool,
    permission_mode: PermissionMode,
) !command_admission.PermissionOutcome {
    if (try isRunCommandCall(input, arena, call)) {
        return try defaultRunCommandPermissionOutcome(input, arena, call, permission_mode);
    }
    if (toolApprovalPolicy(input, call.name) == .ask_only) {
        return switch (permission_mode) {
            .ask, .dontAsk => .{ .decision = .permission_required },
            .yolo, .auto => ordinaryPermissionOutcome(.once),
        };
    }
    if (!toolRequiresApproval(input, call.name) and !is_dynamic_tool) {
        return ordinaryPermissionOutcome(.once);
    }
    return switch (permission_mode) {
        .ask, .dontAsk => .{ .decision = .permission_required },
        .yolo, .auto => ordinaryPermissionOutcome(.once),
    };
}

fn resolveFileMutationAdmission(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) !FileMutationAdmission {
    return resolveFileMutationPreflightAdmission(
        permission_mode,
        input.sensitive_file_guard,
        gitWorkTreeWriteScope(input),
        try preflightFileMutation(
            arena,
            call,
            fileMutationPreflightRequest(input, permission_mode, local_grants),
        ),
    );
}

fn resolvePreparedFileMutationAdmission(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    prepared: *PreparedFileMutationCall,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) !FileMutationAdmission {
    return resolveFileMutationPreflightAdmission(
        permission_mode,
        input.sensitive_file_guard,
        gitWorkTreeWriteScope(input),
        try preflightPreparedFileMutation(
            arena,
            call,
            prepared,
            fileMutationPreflightRequest(input, permission_mode, local_grants),
        ),
    );
}

fn fileMutationPreflightRequest(
    input: Input,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) FileMutationPreflightRequest {
    return .{
        .tool_registry = input.tool_registry,
        .workspace_root = input.workspace_root,
        .access_scope = input.access_scope,
        .permission_rules = input.permission_rules,
        .session_grants = input.permission_grants,
        .permission_mode = permission_mode,
        .local_grants = local_grants,
        .can_prompt = input.permission_prompter != null,
        .sensitive_file_guard = input.sensitive_file_guard,
        .session_permission_state = input.session_permission_state,
    };
}

fn resolveFileMutationPreflightAdmission(
    permission_mode: PermissionMode,
    sensitive_file_guard: bool,
    git_write_scope: ?workspace_access.AccessScope,
    preflight: FileMutationPreflight,
) !FileMutationAdmission {
    return switch (preflight) {
        .tool_failure => |reason| .{ .resolved = .{ .tool_failure = reason } },
        .policy_denied => .{ .resolved = .{ .decision = .policy_denied } },
        .allowed => |authorization| .{ .resolved = .{
            .decision = .once,
            .execution_authority = .{ .file_mutation = authorization },
        } },
        .permission_required, .prompt => |authorization| blk: {
            if (fileMutationAuthorizationNeedsNoPrompt(permission_mode, sensitive_file_guard, git_write_scope, authorization)) {
                break :blk .{ .resolved = .{
                    .decision = .once,
                    .execution_authority = .{ .file_mutation = authorization },
                } };
            }
            if (permission_mode == .dontAsk) break :blk .{ .resolved = dontAskDeniedOutcome(
                if (fileMutationTargetsContainConfiguredAsk(authorization.policy_targets))
                    .configured_rule
                else
                    .approval_required,
            ) };
            break :blk .{ .prompt = .{
                .authorization = authorization,
            } };
        },
    };
}

fn planModeOutcome(input: Input, arena: Allocator, call: ToolCall) !?command_admission.PermissionOutcome {
    const state = input.plan_mode orelse return null;
    if (!state.isActive()) return null;
    const tool = input.tool_registry.lookup(call.name) orelse {
        if (!isAvailableDynamicTool(input, call.name)) return null;
        return .{ .tool_failure = try plan_mode.mutationRefusal(arena, call.name) };
    };
    if (tool.runtime_provider == .verb_host) return null;
    if (tool.executor_kind == .exit_plan_mode) return try planExitOutcome(input, arena, call, state);
    if (tool_dispatch.callIsPlanReadOnly(arena, tool, call.arguments_json, input.workspace_root)) return null;
    if (plan_mode.callWritesPlanFile(arena, call.name, call.arguments_json, input.workspace_root)) return null;
    return .{ .tool_failure = try plan_mode.toolRefusal(arena, call.name, input.workspace_root) };
}

fn planFileWriteMode(input: Input, arena: Allocator, call: ToolCall, requested_mode: PermissionMode) PermissionMode {
    const state = input.plan_mode orelse return requested_mode;
    if (!state.isActive()) return requested_mode;
    if (!plan_mode.callWritesPlanFile(arena, call.name, call.arguments_json, input.workspace_root)) return requested_mode;
    return .auto;
}

fn planExitOutcome(input: Input, arena: Allocator, call: ToolCall, state: *plan_mode.State) !command_admission.PermissionOutcome {
    _ = state.takeReview();
    const plan_text = exitPlanText(input, arena, call) orelse
        return .{ .tool_failure = try plan_mode.missingPlanMessage(arena, input.workspace_root) };
    const prompter = input.permission_prompter orelse return .{ .tool_failure = plan_mode.exit_requires_prompt_message };
    const labels = exitPlanOptionLabels(arena, call);
    var response = prompter.request(
        std.heap.c_allocator,
        .{
            .label = plan_mode.approval_label,
            .command = plan_text,
            .amendment_allowed = true,
            .choice_labels = labels,
        },
        call,
        null,
        null,
    ) catch |err| switch (err) {
        error.PermissionPromptUnavailable => return .{ .tool_failure = plan_mode.exit_requires_prompt_message },
        else => return err,
    };
    defer response.deinit();
    switch (planReviewChoice(&response)) {
        .reject => return .{
            .decision = .deny,
            .denial_reason = .user_denied,
            .tool_failure = plan_mode.rejected_message,
        },
        .dismissed => state.recordReview(.dismissed()),
        .revise => state.recordReview(.revise(response.feedback)),
        .approve => {
            const selected_label = if (response.selected_option) |index|
                if (index < labels.len) labels[index] else null
            else
                null;
            const saved_location = if (input.plan_saver) |saver| saver.save(arena, plan_text) catch null else null;
            state.recordReview(.approved(selected_label, saved_location));
        },
    }
    return permissionOutcomeForDecision(input, arena, call, .once, .interactive_once);
}

fn goalStartOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
) !?command_admission.PermissionOutcome {
    if (!std.mem.eql(u8, call.name, start_permission.create_goal_tool_name)) return null;
    if (input.tool_registry.lookup(call.name)) |tool| {
        if (tool.executor_kind != .create_goal) return null;
    }
    const variant = start_permission.variantFor(.goal, permission_mode) orelse return null;
    const prompter = input.permission_prompter orelse return null;
    var response = prompter.request(
        std.heap.c_allocator,
        .{
            .label = variant.title,
            .explanation = try goalStartSubject(arena, call),
            .amendment_allowed = false,
            .choice_labels = variant.extra_row_labels,
        },
        call,
        null,
        null,
    ) catch |err| switch (err) {
        error.PermissionPromptUnavailable => return null,
        else => return err,
    };
    defer response.deinit();
    const declined = response.decision.isDenied() or
        (if (response.selected_option) |row| variant.declines(row) else false);
    if (!declined) return null;
    return .{
        .decision = .deny,
        .denial_reason = .user_denied,
        .tool_failure = try std.fmt.allocPrint(arena, start_permission.cancelled_format, .{call.name}),
    };
}

const GoalStartArguments = struct {
    objective: []const u8 = "",
    completionCriterion: ?[]const u8 = null,
};

fn goalStartSubject(arena: Allocator, call: ToolCall) ![]const u8 {
    const parsed = std.json.parseFromSliceLeaky(
        GoalStartArguments,
        arena,
        call.arguments_json,
        .{ .ignore_unknown_fields = true },
    ) catch GoalStartArguments{};
    const criterion = parsed.completionCriterion orelse "";
    const subject = if (criterion.len == 0)
        try std.fmt.allocPrint(arena, "{s}{s}", .{ start_permission.goal_subject_prefix, parsed.objective })
    else
        try std.fmt.allocPrint(arena, "{s}{s} · {s}{s}", .{
            start_permission.goal_subject_prefix,
            parsed.objective,
            start_permission.goal_criterion_prefix,
            criterion,
        });
    return text_utils.utf8PrefixByBytes(subject, max_goal_start_subject_bytes);
}

const max_goal_start_subject_bytes: usize = 256;

fn planReviewChoice(response: *const permission_request.OwnedPermissionResponse) permission_request.PlanReviewChoice {
    if (response.plan_review) |choice| return choice;
    if (!response.decision.isDenied()) return .approve;
    const feedback = response.feedback orelse return .reject;
    return if (feedback.len == 0) .reject else .revise;
}

const ExitPlanArguments = struct {
    plan: []const u8 = "",
    options: ?[]const struct { label: []const u8 = "" } = null,
};

fn exitPlanOptionLabels(arena: Allocator, call: ToolCall) []const []const u8 {
    const parsed = std.json.parseFromSliceLeaky(
        ExitPlanArguments,
        arena,
        call.arguments_json,
        .{ .ignore_unknown_fields = true },
    ) catch return &.{};
    const options = parsed.options orelse return &.{};
    const labels = arena.alloc([]const u8, options.len) catch return &.{};
    for (options, labels) |option, *label| label.* = option.label;
    return labels;
}

fn exitPlanText(input: Input, arena: Allocator, call: ToolCall) ?[]const u8 {
    const blank = " \t\r\n";
    if (std.json.parseFromSliceLeaky(
        ExitPlanArguments,
        arena,
        call.arguments_json,
        .{ .ignore_unknown_fields = true },
    )) |parsed| {
        const argument = std.mem.trim(u8, parsed.plan, blank);
        if (argument.len > 0) return argument;
    } else |_| {}
    const stored = plan_mode.readPlanFile(arena, input.workspace_root) orelse return null;
    return std.mem.trim(u8, stored, blank);
}

pub fn requestPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    requested_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) !command_admission.PermissionOutcome {
    if (try planModeOutcome(input, arena, call)) |outcome| return outcome;
    if (try goalStartOutcome(input, arena, call, requested_mode)) |outcome| return outcome;
    const permission_mode = planFileWriteMode(input, arena, call, requested_mode);
    if (input.session_permission_state == null) {
        if (input.session_permission_state_provider) |provider| {
            var snapshot = try provider.snapshot(arena);
            defer snapshot.deinit(arena);
            var resolved = input;
            resolved.session_permission_state = &snapshot;
            resolved.session_permission_state_provider = null;
            return requestPermissionOutcomeResolved(
                resolved,
                arena,
                call,
                permission_mode,
                local_grants,
            );
        }
    }
    return requestPermissionOutcomeResolved(
        input,
        arena,
        call,
        permission_mode,
        local_grants,
    );
}

fn requestPermissionOutcomeResolved(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) !command_admission.PermissionOutcome {
    if (file_mutation_contract.isToolName(call.name) and
        (input.tool_registry.lookup(call.name) == null or
            input.tool_registry.lookup(call.name).?.executor_kind != .host))
    {
        return requestFileMutationPermissionOutcome(
            input,
            arena,
            call,
            permission_mode,
            local_grants,
        );
    }
    if (permission_mode == .auto and std.mem.eql(u8, call.name, ask_user_question_tool_name)) {
        return .{ .tool_failure = ask_user_question_auto_denial };
    }
    const is_mcp_tool = isAvailableDynamicTool(input, call.name);
    const command_call = try isRunCommandCall(input, arena, call);
    if (permission_mode == .dontAsk and command_call and try isCriticalRemovalCall(input, arena, call)) {
        return dontAskDeniedOutcome(.approval_required);
    }
    if (!toolHasPermissionContract(input, call.name) and
        !is_mcp_tool and
        !command_call)
    {
        return ordinaryPermissionOutcome(.once);
    }
    const permission_name = try permissionNameForCall(input, arena, call);
    const target_kind = try permissionTargetKindForCall(input, arena, call);
    var targets = permissionTargetsForCall(input, arena, call) catch |err| {
        if (try permissionTargetResolutionFailureMessage(arena, call, err)) |failure| {
            return .{ .tool_failure = failure };
        }
        return err;
    };
    defer targets.deinit(arena);
    const vision_path_authority = visionPathExecutionAuthority(
        arena,
        call,
        targets.items,
    ) catch |err| switch (err) {
        error.InvalidToolArguments => return .{
            .tool_failure = "Vision paths must reference regular files.",
        },
        else => return err,
    };
    const policy_targets = if (vision_path_authority) |authority|
        try visionPathPermissionTargets(arena, authority)
    else
        targets.items;
    const vision_path_label = if (vision_path_authority) |authority|
        try formatVisionPathPermissionLabel(arena, authority)
    else
        null;
    const shell_grant_call = std.mem.eql(u8, permissions.permissionNameForTool(permission_name), "bash");
    if (shell_grant_call) shell_snapshot.processOwner().checkStartupFiles();

    const grants_apply = !(shell_grant_call and shellCallRequestsReload(arena, call));
    var configured_ask = false;
    var configured_reason: ?[]const u8 = null;
    var sensitive_file_ask = false;
    const sensitive_file_guarded = input.sensitive_file_guard and permission_mode != .auto and isPathTargetKind(target_kind);
    var all_targets_authorized_by_rule = true;
    var used_session_grant = false;
    var grant_epoch: ?u64 = null;
    for (policy_targets) |target| {
        switch (try permissions.ruleDecisionFor(arena, input.permission_rules, input.workspace_root, permission_name, target.path, target_kind)) {
            .deny => return .{
                .decision = .policy_denied,
                .rule_reason = try permissions.configuredRuleReasonFor(arena, input.permission_rules, input.workspace_root, permission_name, target.path, target_kind),
            },
            .allow => {},
            .ask => {
                if (grants_apply and permissions.sessionGrantAllowed(local_grants, permission_name, target.path)) {
                    used_session_grant = true;
                    if (shell_grant_call) grant_epoch = shell_snapshot.processOwner().shellGrantEpoch(target.path);
                    continue;
                }
                configured_ask = true;
                if (configured_reason == null) configured_reason = try permissions.configuredRuleReasonFor(arena, input.permission_rules, input.workspace_root, permission_name, target.path, target_kind);
            },
            .none => {
                all_targets_authorized_by_rule = false;
                if (sensitive_file_guarded and
                    (sensitive_file.isSensitiveFile(target.path) or sensitive_file.isGitControlPath(target.path)) and
                    !(grants_apply and permissions.sessionGrantAllowed(local_grants, permission_name, target.path)))
                {
                    sensitive_file_ask = true;
                }
            },
        }
    }
    if (hookAsksForPrompt(input, call)) configured_ask = true;

    if (input.session_permission_state) |state| {
        const key = permissionStateKeyForCall(input, arena, call) catch null;
        if (key) |resolved_key| switch (session_permission_state.decide(state.*, resolved_key)) {
            .deny => return .{
                .decision = .policy_denied,
                .denial_reason = .policy_denied,
            },
            .allow => return bindVisionPathExecutionAuthority(
                try permissionOutcomeForDecision(
                    input,
                    arena,
                    call,
                    .once,
                    .session_state,
                ),
                vision_path_authority,
            ),
            .unresolved => {},
        };
    }

    if (permission_mode == .dontAsk and (configured_ask or sensitive_file_ask)) {
        var denied = dontAskDeniedOutcome(if (configured_ask) .configured_rule else .approval_required);
        denied.rule_reason = configured_reason;
        return denied;
    }

    if (configured_ask) {
        if (input.permission_prompter == null) return .{
            .decision = noninteractivePermissionRequired(call, "configured_rule_ask"),
            .denial_reason = .permission_required,
            .requirement = .configured_rule,
            .rule_reason = configured_reason,
        };
        return bindVisionPathExecutionAuthority(
            try promptPermissionOutcome(
                input,
                arena,
                call,
                vision_path_label,
                .configured_rule,
            ),
            vision_path_authority,
        );
    }

    if (sensitive_file_ask) {
        if (input.permission_prompter == null) return .{
            .decision = noninteractivePermissionRequired(call, "sensitive_file_ask"),
            .denial_reason = .permission_required,
            .requirement = .approval_required,
        };
        return bindVisionPathExecutionAuthority(
            try promptPermissionOutcome(
                input,
                arena,
                call,
                vision_path_label,
                .approval_required,
            ),
            vision_path_authority,
        );
    }

    if (command_call and
        (all_targets_authorized_by_rule or (grants_apply and sessionGrantsAllowAll(local_grants, permission_name, policy_targets))) and
        try dangerousCommandAsksBeforeGrants(input, arena, call, permission_mode))
    {
        if (input.permission_prompter == null) return .{
            .decision = noninteractivePermissionRequired(call, "dangerous_command_ask"),
            .denial_reason = .permission_required,
            .requirement = .approval_required,
        };
        return promptPermissionOutcome(
            input,
            arena,
            call,
            vision_path_label,
            .approval_required,
        );
    }

    if (all_targets_authorized_by_rule) {
        return bindVisionPathExecutionAuthority(withShellGrantEpoch(try permissionOutcomeForDecision(
            input,
            arena,
            call,
            .once,
            if (used_session_grant) .session_grant else .configured_rule,
        ), grant_epoch), vision_path_authority);
    }
    if (grants_apply and sessionGrantsAllowAll(local_grants, permission_name, policy_targets)) {
        if (shell_grant_call and policy_targets.len > 0) {
            grant_epoch = shell_snapshot.processOwner().shellGrantEpoch(policy_targets[0].path);
        }
        return bindVisionPathExecutionAuthority(
            withShellGrantEpoch(
                try permissionOutcomeForDecision(input, arena, call, .once, .session_grant),
                grant_epoch,
            ),
            vision_path_authority,
        );
    }
    if (input.host_sandbox_default == .allow_sandboxed and
        !hostToolNeedsAskApproval(input, call, permission_mode) and
        try isRunCommandCall(input, arena, call))
    {
        return shellPermissionOutcome(
            try runCommandContext(input, arena, call),
            .once,
            .js_host,
        );
    }
    const resolution = try resolveOrdinaryPermissionOutcome(
        input,
        arena,
        call,
        is_mcp_tool,
        permission_mode,
    );
    if (resolution.decision != .permission_required) {
        return bindVisionPathExecutionAuthority(resolution, vision_path_authority);
    }
    if (permission_mode == .dontAsk) return dontAskDeniedOutcome(.approval_required);
    const unavailable_requirement: command_admission.PermissionRequirement = .approval_required;
    if (input.permission_prompter == null) {
        _ = noninteractivePermissionRequired(
            call,
            if (try isRunCommandCall(input, arena, call))
                "command_requires_approval"
            else
                "tool_requires_approval",
        );
        var blocked = resolution;
        blocked.denial_reason = .permission_required;
        blocked.requirement = unavailable_requirement;
        return bindVisionPathExecutionAuthority(blocked, vision_path_authority);
    }
    return bindVisionPathExecutionAuthority(
        try promptPermissionOutcome(
            input,
            arena,
            call,
            vision_path_label,
            unavailable_requirement,
        ),
        vision_path_authority,
    );
}

fn exactApprovalLocalGrants(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    local_grants: []const PermissionGrant,
    authority: command_admission.ToolExecutionAuthority,
) ![]const PermissionGrant {
    switch (authority) {
        .file_mutation => |authorization| {
            const offer = authorization.grant_offer orelse return local_grants;
            const grants = try arena.alloc(
                PermissionGrant,
                local_grants.len + offer.grants.len,
            );
            @memcpy(grants[0..local_grants.len], local_grants);
            @memcpy(grants[local_grants.len..], offer.grants);
            return grants;
        },
        .ordinary, .run_command => {
            var targets = try permissionTargetsForCall(input, arena, call);
            defer targets.deinit(arena);
            const permission_name = try permissionNameForCall(input, arena, call);
            const grants = try arena.alloc(
                PermissionGrant,
                local_grants.len + targets.items.len,
            );
            @memcpy(grants[0..local_grants.len], local_grants);
            for (targets.items, grants[local_grants.len..]) |target, *grant| {
                grant.* = .{
                    .tool_name = try arena.dupe(
                        u8,
                        permissions.permissionNameForTool(permission_name),
                    ),
                    .target_path = try arena.dupe(
                        u8,
                        permissions.patternForSessionGrantMatch(
                            permission_name,
                            target.path,
                        ),
                    ),
                };
            }
            return grants;
        },
        .vision_paths => |vision_authority| {
            const grants = try arena.alloc(
                PermissionGrant,
                local_grants.len + vision_authority.targets.len,
            );
            @memcpy(grants[0..local_grants.len], local_grants);
            for (vision_authority.targets, grants[local_grants.len..]) |target, *grant| {
                grant.* = .{
                    .tool_name = try arena.dupe(
                        u8,
                        permissions.permissionNameForTool(call.name),
                    ),
                    .target_path = try arena.dupe(
                        u8,
                        permissions.patternForSessionGrantMatch(
                            call.name,
                            target.canonical_path,
                        ),
                    ),
                };
            }
            return grants;
        },
    }
}

pub fn revalidateLiveActionPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    requested_mode: PermissionMode,
    local_grants: []const PermissionGrant,
    authority: command_admission.ToolExecutionAuthority,
    human_approval: command_admission.HumanApprovalProvenance,
) !command_admission.PermissionOutcome {
    if (try planModeOutcome(input, arena, call)) |outcome| return outcome;
    const permission_mode = planFileWriteMode(input, arena, call, requested_mode);
    const revalidation_grants = if (human_approval != .none)
        try exactApprovalLocalGrants(
            input,
            arena,
            call,
            local_grants,
            authority,
        )
    else
        local_grants;
    var answered_input = input;
    answered_input.dangerous_command_ask_answered = human_approval != .none;
    var outcome = switch (authority) {
        .ordinary => try requestPermissionOutcome(
            answered_input,
            arena,
            call,
            permission_mode,
            revalidation_grants,
        ),
        .run_command => |expected| blk: {
            const outcome = try requestPermissionOutcome(
                answered_input,
                arena,
                call,
                permission_mode,
                revalidation_grants,
            );
            if (!outcome.decision.isDenied()) {
                const actual = switch (outcome.execution_authority orelse
                    break :blk invalidLiveActionOutcome()) {
                    .run_command => |value| value,
                    .ordinary, .file_mutation, .vision_paths => break :blk invalidLiveActionOutcome(),
                };
                if (!commandAuthorityFingerprint(expected).eql(
                    commandAuthorityFingerprint(actual),
                )) break :blk invalidLiveActionOutcome();
            }
            break :blk outcome;
        },
        .file_mutation => try requestPermissionOutcome(
            input,
            arena,
            call,
            permission_mode,
            revalidation_grants,
        ),
        .vision_paths => |expected| blk: {
            const canonical_call = try canonicalVisionPathCall(arena, call, expected);
            const refreshed = try requestPermissionOutcome(
                input,
                arena,
                canonical_call,
                permission_mode,
                revalidation_grants,
            );
            if (!refreshed.decision.isDenied()) {
                const actual = switch (refreshed.execution_authority orelse
                    break :blk invalidLiveActionOutcome()) {
                    .vision_paths => |value| value,
                    .ordinary, .run_command, .file_mutation => break :blk invalidLiveActionOutcome(),
                };
                if (!visionPathAuthoritiesEqual(expected, actual)) {
                    break :blk invalidLiveActionOutcome();
                }
            }
            break :blk refreshed;
        },
    };
    if (human_approval != .none and
        outcome.tool_failure == null and
        !outcome.decision.isDenied())
    {
        outcome.decision = switch (human_approval) {
            .once => .once,
            .always => .always,
            .always_tree => .always_tree,
            .none => unreachable,
        };
        outcome.human_approval = human_approval;
    }
    return outcome;
}

fn commandAuthorityFingerprint(
    authority: command_admission.CommandExecutionAuthority,
) command_admission.AdmissionFingerprint {
    return switch (authority) {
        .direct_only => |fingerprint| fingerprint,
        .shell_allowed => |allowed| allowed.fingerprint,
    };
}

fn canonicalVisionPathCall(
    arena: Allocator,
    call: ToolCall,
    authority: command_admission.VisionPathExecutionAuthority,
) !ToolCall {
    var request = try vision_contracts.parse_vision_request(arena, call.arguments_json);
    defer request.deinit(arena);
    const paths = request.paths() orelse return error.InvalidToolArguments;
    if (paths.len != authority.targets.len) return error.InvalidToolArguments;

    const canonical_paths = try arena.alloc([]const u8, authority.targets.len);
    for (authority.targets, canonical_paths) |target, *canonical_path| {
        canonical_path.* = target.canonical_path;
    }

    var arguments: std.Io.Writer.Allocating = .init(arena);
    defer arguments.deinit();
    try arguments.writer.writeAll("{\"paths\":");
    try std.json.Stringify.value(canonical_paths, .{}, &arguments.writer);
    try arguments.writer.writeAll(",\"focus\":");
    try std.json.Stringify.value(request.focus, .{}, &arguments.writer);
    try arguments.writer.writeByte('}');
    return .{
        .id = call.id,
        .name = call.name,
        .arguments_json = try arguments.toOwnedSlice(),
    };
}

fn visionPathAuthoritiesEqual(
    expected: command_admission.VisionPathExecutionAuthority,
    actual: command_admission.VisionPathExecutionAuthority,
) bool {
    if (expected.targets.len != actual.targets.len) return false;
    for (expected.targets, actual.targets) |expected_target, actual_target| {
        if (!std.mem.eql(
            u8,
            expected_target.canonical_path,
            actual_target.canonical_path,
        ) or !std.meta.eql(expected_target.identity, actual_target.identity)) {
            return false;
        }
    }
    return true;
}

fn invalidLiveActionOutcome() command_admission.PermissionOutcome {
    return .{
        .decision = .policy_denied,
        .denial_reason = .policy_denied,
        .tool_failure = "live authority no longer matches the prepared action",
    };
}

fn requestFileMutationPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) !command_admission.PermissionOutcome {
    return requestFileMutationPermissionOutcomeFromAdmission(
        input,
        arena,
        call,
        try resolveFileMutationAdmission(
            input,
            arena,
            call,
            permission_mode,
            local_grants,
        ),
    );
}

pub fn requestPreparedFileMutationPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    prepared: *PreparedFileMutationCall,
    requested_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) !command_admission.PermissionOutcome {
    if (try planModeOutcome(input, arena, call)) |outcome| return outcome;
    const permission_mode = planFileWriteMode(input, arena, call, requested_mode);
    return requestFileMutationPermissionOutcomeFromAdmission(
        input,
        arena,
        call,
        try resolvePreparedFileMutationAdmission(
            input,
            arena,
            call,
            prepared,
            permission_mode,
            local_grants,
        ),
    );
}

fn withFileRuleDenialReason(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    outcome: command_admission.PermissionOutcome,
) command_admission.PermissionOutcome {
    if (outcome.decision != .policy_denied or outcome.rule_reason != null or outcome.tool_failure != null) return outcome;
    const Args = struct { path: ?[]const u8 = null };
    const parsed = std.json.parseFromSliceLeaky(Args, arena, call.arguments_json, .{ .ignore_unknown_fields = true }) catch return outcome;
    const path = parsed.path orelse return outcome;
    const target = if (std.Io.Dir.path.isAbsolute(path))
        path
    else
        std.Io.Dir.path.join(arena, &.{
            input.workspace_root,
            if (std.mem.startsWith(u8, path, "./")) path[2..] else path,
        }) catch return outcome;
    var reasoned = outcome;
    reasoned.rule_reason = permissions.configuredFileRuleReasonFor(input.permission_rules, input.workspace_root, call.name, target);
    return reasoned;
}

fn requestFileMutationPermissionOutcomeFromAdmission(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    admission: FileMutationAdmission,
) !command_admission.PermissionOutcome {
    return switch (admission) {
        .resolved => |outcome| withFileRuleDenialReason(input, arena, call, outcome),
        .prompt => |pending| blk: {
            const unavailable: command_admission.PermissionOutcome = .{
                .decision = .permission_required,
                .denial_reason = .permission_required,
                .requirement = if (fileMutationTargetsContainConfiguredAsk(
                    pending.authorization.policy_targets,
                ))
                    .configured_rule
                else
                    .approval_required,
            };
            const prompter = input.permission_prompter orelse break :blk unavailable;
            var authorization = pending.authorization;
            const request_view = try fileMutationPermissionRequest(
                "file_mutation",
                authorization,
            );
            const review = if (authorization.prepared) |*prepared|
                &prepared.review
            else
                return error.RequestProjectionTooLarge;
            var response = prompter.request(
                std.heap.c_allocator,
                request_view,
                call,
                review,
                authorization.grant_offer.?.grants,
            ) catch |err| switch (err) {
                error.PermissionPromptUnavailable => break :blk unavailable,
                else => return err,
            };
            defer response.deinit();
            var outcome: command_admission.PermissionOutcome = .{
                .decision = response.decision,
                .execution_authority = if (response.decision.isDenied()) null else .{
                    .file_mutation = authorization,
                },
                .human_approval = humanApprovalProvenance(response.decision),
            };
            if (response.decision == .deny) {
                outcome.denial_reason = .user_denied;
            }
            outcome.feedback = try copyPermissionFeedback(arena, &response);
            break :blk outcome;
        },
    };
}

fn fileMutationPermissionRequest(
    label: []const u8,
    authorization: file_mutation_contract.FileExecutionAuthorization,
) permission_request.RequestCloneError!permission_request.PermissionRequest {
    const prepared = authorization.prepared orelse
        return error.RequestProjectionTooLarge;
    const offer = authorization.grant_offer orelse
        return error.RequestProjectionTooLarge;
    const intent = authorization.approval_intent orelse
        return error.RequestProjectionTooLarge;
    const request: permission_request.PermissionRequest = .{
        .label = label,
        .file = .{
            .kind = prepared.kind,
            .intent = intent,
            .preview = prepared.preview,
            .scope = offer.scope,
        },
    };
    _ = try permission_request.fileRequestFootprint(request);
    return request;
}

fn ordinaryPermissionOutcome(decision: ToolPermissionDecision) command_admission.PermissionOutcome {
    return .{
        .decision = decision,
        .execution_authority = if (decision.isDenied()) null else .ordinary,
    };
}

fn dontAskDeniedOutcome(requirement: command_admission.PermissionRequirement) command_admission.PermissionOutcome {
    return .{
        .decision = .permission_required,
        .denial_reason = .dont_ask_denied,
        .requirement = requirement,
    };
}

fn visionPathExecutionAuthority(
    arena: Allocator,
    call: ToolCall,
    targets: []const permissions.PermissionCallTarget,
) !?command_admission.VisionPathExecutionAuthority {
    if (!std.mem.eql(u8, call.name, "vision") or
        targets.len == 0 or
        !std.mem.eql(u8, targets[0].role, "image"))
    {
        return null;
    }
    const execution_targets = try arena.alloc(
        command_admission.VisionPathExecutionTarget,
        targets.len,
    );
    for (targets, execution_targets) |target, *execution_target| {
        if (!std.mem.eql(u8, target.role, "image")) {
            return error.InvalidToolArguments;
        }
        var source = image_attachments.openVisionRegularFile(target.path) catch
            return error.InvalidToolArguments;
        defer source.close();
        execution_target.* = .{
            .canonical_path = try arena.dupe(u8, target.path),
            .identity = source.identity,
        };
    }
    return .{ .targets = execution_targets };
}

fn visionPathPermissionTargets(
    arena: Allocator,
    authority: command_admission.VisionPathExecutionAuthority,
) ![]const permissions.PermissionCallTarget {
    const targets = try arena.alloc(
        permissions.PermissionCallTarget,
        authority.targets.len,
    );
    for (authority.targets, targets) |execution_target, *target| {
        target.* = .{
            .role = "image",
            .path = @constCast(execution_target.canonical_path),
        };
    }
    return targets;
}

fn bindVisionPathExecutionAuthority(
    outcome: command_admission.PermissionOutcome,
    vision_authority: ?command_admission.VisionPathExecutionAuthority,
) !command_admission.PermissionOutcome {
    const authority = vision_authority orelse return outcome;
    var bound = outcome;
    if (bound.execution_authority) |execution_authority| {
        switch (execution_authority) {
            .ordinary => bound.execution_authority = .{ .vision_paths = authority },
            .run_command, .file_mutation, .vision_paths => {},
        }
    }
    return bound;
}

fn permissionOutcomeForDecision(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    decision: ToolPermissionDecision,
    source: command_admission.ShellAuthorizationSource,
) !command_admission.PermissionOutcome {
    if (decision.isDenied()) return .{ .decision = decision };
    if (!try isRunCommandCall(input, arena, call)) {
        return ordinaryPermissionOutcome(decision);
    }
    const command_ctx = runCommandContext(input, arena, call) catch {
        return .{ .decision = .permission_required };
    };
    return shellPermissionOutcome(command_ctx, decision, source);
}

fn shellCallRequestsReload(arena: Allocator, call: ToolCall) bool {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, call.arguments_json, .{}) catch return false;
    if (value != .object) return false;
    const args = if (value.object.get("request")) |request| switch (request) {
        .object => |object| object,
        else => return false,
    } else value.object;
    const reload = args.get("reload") orelse return false;
    return reload == .bool and reload.bool;
}

test "shell reload detection reads top-level and wrapped arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { arguments_json: []const u8, reload: bool }{
        .{ .arguments_json = "{\"command\":\"git status\",\"reload\":true}", .reload = true },
        .{ .arguments_json = "{\"request\":{\"action\":\"run\",\"command\":\"git status\",\"reload\":true}}", .reload = true },
        .{ .arguments_json = "{\"command\":\"git status\",\"reload\":false}", .reload = false },
        .{ .arguments_json = "{\"command\":\"git status\"}", .reload = false },
        .{ .arguments_json = "{\"command\":\"git status\",\"reload\":\"true\"}", .reload = false },
        .{ .arguments_json = "{\"request\":\"{\\\"reload\\\":true}\"}", .reload = false },
        .{ .arguments_json = "not json", .reload = false },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.reload, shellCallRequestsReload(arena, .{
            .id = "reload",
            .name = "Bash",
            .arguments_json = case.arguments_json,
        }));
    }
}

fn withShellGrantEpoch(
    outcome: command_admission.PermissionOutcome,
    grant_epoch: ?u64,
) command_admission.PermissionOutcome {
    var bound = outcome;
    if (bound.execution_authority) |*authority| switch (authority.*) {
        .run_command => |*command| switch (command.*) {
            .shell_allowed => |*shell| shell.grant_epoch = grant_epoch,
            .direct_only => {},
        },
        else => {},
    };
    return bound;
}

fn shellPermissionOutcome(
    command_ctx: command_admission.CommandContext,
    decision: ToolPermissionDecision,
    source: command_admission.ShellAuthorizationSource,
) command_admission.PermissionOutcome {
    if (decision.isDenied()) return .{ .decision = decision };
    return .{
        .decision = decision,
        .execution_authority = .{ .run_command = .{ .shell_allowed = .{
            .fingerprint = .init(command_ctx),
            .source = source,
        } } },
    };
}

fn permissionOutcomeForResponse(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    response: *const permission_request.OwnedPermissionResponse,
    source: command_admission.ShellAuthorizationSource,
) !command_admission.PermissionOutcome {
    var outcome = try permissionOutcomeForDecision(
        input,
        arena,
        call,
        response.decision,
        source,
    );
    outcome.human_approval = humanApprovalProvenance(response.decision);
    if (response.decision == .deny) outcome.denial_reason = .user_denied;
    outcome.feedback = try copyPermissionFeedback(arena, response);
    return outcome;
}

fn humanApprovalProvenance(
    decision: ToolPermissionDecision,
) command_admission.HumanApprovalProvenance {
    return switch (decision) {
        .once => .once,
        .always => .always,
        .always_tree => .always_tree,
        .deny, .policy_denied, .permission_required => .none,
    };
}

fn hookAsksForPrompt(input: Input, call: ToolCall) bool {
    const prompter = input.permission_prompter orelse return false;
    return prompter.hookAsks(call.id);
}

fn promptPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    label_override: ?[]const u8,
    unavailable_requirement: command_admission.PermissionRequirement,
) !command_admission.PermissionOutcome {
    const request = try interactivePermissionRequest(input, arena, call, label_override);
    const unavailable: command_admission.PermissionOutcome = .{
        .decision = .permission_required,
        .denial_reason = .permission_required,
        .requirement = unavailable_requirement,
    };
    const prompter = input.permission_prompter orelse return unavailable;
    const grant_offer = if (try isRunCommandCall(input, arena, call))
        try exactApprovalLocalGrants(input, arena, call, &.{}, .ordinary)
    else
        null;
    var response = prompter.request(
        std.heap.c_allocator,
        request,
        call,
        null,
        grant_offer,
    ) catch |err| switch (err) {
        error.PermissionPromptUnavailable => return unavailable,
        else => return err,
    };
    defer response.deinit();
    const outcome = try permissionOutcomeForResponse(
        input,
        arena,
        call,
        &response,
        if (response.decision == .always or response.decision == .always_tree) .interactive_always else .interactive_once,
    );
    return outcome;
}

fn requestWorkerPermission(
    raw: *anyopaque,
    alloc: Allocator,
    request: permission_request.PermissionRequest,
    _: ToolCall,
    review: ?*const diff_mod.FileReview,
    _: ?[]const PermissionGrant,
) anyerror!permission_request.OwnedPermissionResponse {
    const worker: *WorkerRuntime = @ptrCast(@alignCast(raw));
    return worker.requestPermissionBlockingWithReview(alloc, request, review);
}

pub fn workerPrompter(worker: *WorkerRuntime) permission_prompter.Prompter {
    return .{
        .context = @ptrCast(worker),
        .request_fn = requestWorkerPermission,
    };
}

fn copyPermissionFeedback(
    arena: Allocator,
    response: *const permission_request.OwnedPermissionResponse,
) !?[]const u8 {
    const feedback = response.feedback orelse return null;
    if (feedback.len == 0) return null;
    return @as([]const u8, try arena.dupe(u8, feedback));
}

fn defaultRunCommandPermissionOutcome(
    input: anytype,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
) !command_admission.PermissionOutcome {
    if (hostToolNeedsAskApproval(input, call, permission_mode)) return .{ .decision = .permission_required };
    const command_ctx = runCommandContext(input, arena, call) catch {
        return .{ .decision = .permission_required };
    };
    return switch (command_admission.defaultForRunCommand(
        arena,
        command_ctx,
        permission_mode,
    )) {
        .direct_only => |fingerprint| .{
            .decision = .once,
            .execution_authority = .{ .run_command = .{ .direct_only = fingerprint } },
        },

        .approval_required => |reason| switch (permission_mode) {
            .ask, .dontAsk => .{ .decision = .permission_required },
            .yolo => if (reason == .unsafe_git or
                try command_admission.writesGitControlPath(arena, command_ctx.command) or
                (input.sensitive_file_guard and try command_admission.dangerousShellCommand(arena, command_ctx.command)))
                .{ .decision = .permission_required }
            else
                shellPermissionOutcome(command_ctx, .once, .yolo),
            .auto => if (reason == .unsafe_git)
                .{ .tool_failure = unsafe_git_hold_output }
            else
                shellPermissionOutcome(command_ctx, .once, .auto_mode),
        },
    };
}

pub const CommandScope = struct {
    workspace_root: []const u8,
    tool_registry: tool_dispatch.Registry,
    sensitive_file_guard: bool = true,
};

pub fn commandPermissionOutcome(
    scope: CommandScope,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
) !command_admission.PermissionOutcome {
    return defaultRunCommandPermissionOutcome(scope, arena, call, permission_mode);
}

fn dangerousCommandAsksBeforeGrants(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
) !bool {
    if (permission_mode != .ask and permission_mode != .yolo) return false;
    if (!input.sensitive_file_guard or input.dangerous_command_ask_answered) return false;
    const command_ctx = runCommandContext(input, arena, call) catch return false;
    return command_admission.dangerousShellCommand(arena, command_ctx.command);
}

fn isCriticalRemovalCall(input: Input, arena: Allocator, call: ToolCall) !bool {
    const command_ctx = runCommandContext(input, arena, call) catch return false;
    return command_admission.criticalRemovalShellCommand(arena, command_ctx.command, input.workspace_root);
}

const ask_user_question_tool_name = "AskUserQuestion";

const ask_user_question_auto_denial =
    "AskUserQuestion is disabled while auto permission mode is active; decide and continue.";

const unsafe_git_hold_output =
    "fx did not run this git command. It could not run git here with every program this repository's config " ++
    "names turned off, and plain git could start them. Inspect files with read_file, glob_files or grep_files, " ++
    "or ask the user to run git themselves.";

pub fn runCommandContext(
    input: anytype,
    arena: Allocator,
    call: ToolCall,
) !command_admission.CommandContext {
    if (!try isRunCommandCall(input, arena, call)) return error.NotRunCommand;
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const command = try tool_args.requiredStringArg(args, "command");
    const execution_mode: command_admission.CommandExecutionMode =
        if (tool_args.optionalBoolArg(args, "tty") orelse false) .tty else .captured;
    const tool = registeredTool(input, call.name) orelse return error.NotRunCommand;
    const cwd = switch (tool.captured_command_host) {
        .workspace_clean => try arena.dupe(u8, input.workspace_root),
        .native => blk: {
            const cwd_arg = tool_args.nullablePlaceholderStringArg(args, "cwd") orelse ".";
            break :blk if (std.mem.eql(u8, cwd_arg, "."))
                try arena.dupe(u8, input.workspace_root)
            else
                try pathing.resolveWorkspaceOrExternalPath(arena, input.workspace_root, cwd_arg);
        },
    };
    const environment_value: command_environment.Environment = switch (tool.captured_command_host) {
        .workspace_clean => .workspace_clean,
        .native => try nativeCommandEnvironment(arena, args, execution_mode),
    };
    return .{
        .command = command,
        .resolved_cwd = cwd,
        .target_os = builtin.target.os.tag,
        .environment = environment_value,
        .execution_mode = execution_mode,
        .workspace_root = input.workspace_root,
    };
}

fn nativeCommandEnvironment(
    arena: Allocator,
    args: std.json.ObjectMap,
    execution_mode: command_admission.CommandExecutionMode,
) !command_environment.Environment {
    var login_shell_buffer: [4096]u8 = undefined;
    const configured = shell_resolver.configuredLoginShellInto(&login_shell_buffer);
    if (execution_mode == .tty) {
        if (try explicitTtyShell(arena, args)) |shell| {
            return shell_resolver.environmentForShellSpec(arena, configured, shell);
        }
    }
    const profile_raw = tool_args.nullablePlaceholderStringArg(args, "profile");
    const profile: ?command_environment.Profile = if (profile_raw) |raw|
        std.meta.stringToEnum(command_environment.Profile, raw) orelse
            return error.InvalidCommandProfile
    else
        null;
    return shell_resolver.environment(arena, configured, profile);
}

fn explicitTtyShell(
    arena: Allocator,
    args: std.json.ObjectMap,
) !?terminal_contracts.ShellSpec {
    var value = args.get("shell") orelse return null;
    if (value == .null or
        (value == .string and tool_args.isNullPlaceholderText(value.string)))
    {
        return null;
    }
    try tool_args.normalizeCompositeObjectValue(arena, &value);
    if (value != .object) return error.InvalidToolArguments;
    const kind = try tool_args.requiredStringArg(value.object, "kind");
    if (!std.mem.eql(u8, kind, "executable")) return error.InvalidToolArguments;
    return .{ .executable = .{
        .path = try tool_args.requiredStringArg(value.object, "path"),
        .clean_start = tool_args.optionalBoolArg(value.object, "clean_start") orelse false,
    } };
}

pub fn permissionStateKeyForCall(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) !session_permission_state.RuleKey {
    if (file_mutation_contract.isToolName(call.name)) {
        return error.PreparedFileMutationRequired;
    }
    if (try isRunCommandCall(input, arena, call)) {
        const command = try runCommandContext(input, arena, call);
        const command_identity = switch (command.execution_mode) {
            .captured => command.command,
            .tty => try command_environment.ttyPermissionCommandIdentity(
                arena,
                command.environment,
                command.command,
            ),
        };
        return session_permission_state.commandKeyV2(
            arena,
            command_identity,
            command.resolved_cwd,
            switch (command.execution_mode) {
                .captured => "foreground",
                .tty => "tty",
            },
            @tagName(command.target_os),
        );
    }

    var canonical: std.Io.Writer.Allocating = .init(arena);
    defer canonical.deinit();
    try writeIdentityField(&canonical.writer, "fx-permission-state-v1");
    var targets = try permissionTargetsForCall(input, arena, call);
    defer targets.deinit(arena);
    try writeIdentityField(&canonical.writer, call.name);
    try writeIdentityField(&canonical.writer, call.arguments_json);
    for (targets.items) |target| {
        try writeIdentityField(&canonical.writer, target.role);
        try writeIdentityField(&canonical.writer, target.path);
    }
    const bytes = try canonical.toOwnedSlice();
    return session_permission_state.RuleKey.init(.structured_tool, bytes);
}

fn commandPermissionIdentityForContext(
    arena: Allocator,
    command: command_admission.CommandContext,
) ![]const u8 {
    return switch (command.execution_mode) {
        .captured => command_environment.permissionCommandIdentity(
            arena,
            command.environment,
            command.command,
        ),
        .tty => command_environment.ttyPermissionCommandIdentity(
            arena,
            command.environment,
            command.command,
        ),
    };
}

pub const PreparedPermissionStateAction = struct {
    key: session_permission_state.RuleKey,
    display_identity: []const u8,
};

pub fn preparePermissionStateAction(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) !PreparedPermissionStateAction {
    if (!file_mutation_contract.isToolName(call.name)) {
        const request = try interactivePermissionRequest(input, arena, call, null);
        return .{
            .key = try permissionStateKeyForCall(input, arena, call),
            .display_identity = try arena.dupe(u8, request.label),
        };
    }

    var prepared_call = switch (try prepareFileMutationCall(arena, call, .{
        .tool_registry = input.tool_registry,
        .workspace_root = input.workspace_root,
        .access_scope = input.access_scope,
    })) {
        .prepared => |prepared| prepared,

        .not_file_mutation => return error.PermissionStatePreparationFailed,
        .tool_failure => return error.PermissionStatePreparationFailed,
    };
    defer prepared_call.deinit(arena);
    const preflight = try preflightPreparedFileMutation(arena, call, &prepared_call, .{
        .tool_registry = input.tool_registry,
        .workspace_root = input.workspace_root,
        .access_scope = input.access_scope,
        .permission_rules = input.permission_rules,
        .permission_mode = .ask,
        .can_prompt = true,
        .prepare_permission_identity = true,
    });
    const authorization = switch (preflight) {
        .allowed, .prompt, .permission_required => |authorization| authorization,
        .policy_denied => return error.PermissionStatePreparationDenied,
        .tool_failure => return error.PermissionStatePreparationFailed,
    };
    const prepared = authorization.prepared orelse
        return error.PermissionStatePreparationFailed;
    return .{
        .key = try permissionStateKeyForPreparedFileMutation(arena, prepared),
        .display_identity = try filePermissionStateDisplay(arena, prepared),
    };
}

fn permissionStateKeyForPreparedFileMutation(
    arena: Allocator,
    prepared: file_mutation_contract.PreparedFileMutation,
) !session_permission_state.RuleKey {
    var canonical: std.Io.Writer.Allocating = .init(arena);
    defer canonical.deinit();
    try writeIdentityField(&canonical.writer, "fx-permission-state-file-v1");
    try writeIdentityField(&canonical.writer, prepared.tool_name);
    try writeIdentityField(&canonical.writer, &prepared.arguments_hash);
    try writeIdentityField(&canonical.writer, prepared.target_path);
    try writeIdentityField(&canonical.writer, @tagName(prepared.kind));
    switch (prepared.preimage) {
        .absent => try writeIdentityField(&canonical.writer, "preimage-absent"),
        .present => |preimage| {
            try writeIdentityField(&canonical.writer, "preimage-present");
            try writeIdentityField(&canonical.writer, &preimage.content_hash);
        },
    }
    var after_hash: types.ContentHash = undefined;
    std.crypto.hash.sha2.Sha256.hash(prepared.after_content, &after_hash, .{});
    try writeIdentityField(&canonical.writer, &after_hash);
    for (prepared.policy_targets.items) |target| {
        try writeIdentityField(
            &canonical.writer,
            prepared.policy_targets.canonical_target_path[0..target.path_end],
        );
        try writeIdentityField(&canonical.writer, @tagName(target.kind));
        try writeIdentityField(&canonical.writer, @tagName(target.disposition));
        if (target.expected_identity) |identity| {
            try writeIdentityU64(&canonical.writer, identity.device);
            try writeIdentityU64(&canonical.writer, identity.inode);
            try writeIdentityField(&canonical.writer, @tagName(identity.kind));
        } else {
            try writeIdentityField(&canonical.writer, "identity-absent");
        }
    }
    const bytes = try canonical.toOwnedSlice();
    return session_permission_state.RuleKey.init(.file_mutation, bytes);
}

fn filePermissionStateDisplay(
    arena: Allocator,
    prepared: file_mutation_contract.PreparedFileMutation,
) ![]const u8 {
    var after_hash: types.ContentHash = undefined;
    std.crypto.hash.sha2.Sha256.hash(prepared.after_content, &after_hash, .{});
    const after_hex = std.fmt.bytesToHex(after_hash[0..8].*, .lower);
    return switch (prepared.preimage) {
        .absent => try arena.print(
            "{s} {s} preimage=absent after={s}",
            .{ prepared.tool_name, prepared.display_path, &after_hex },
        ),
        .present => |preimage| blk: {
            const before_hex = std.fmt.bytesToHex(
                preimage.content_hash[0..8].*,
                .lower,
            );
            break :blk try arena.print(
                "{s} {s} preimage={s} after={s}",
                .{ prepared.tool_name, prepared.display_path, &before_hex, &after_hex },
            );
        },
    };
}

fn writeIdentityU64(writer: *std.Io.Writer, value: u64) !void {
    var bytes: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .big);
    try writeIdentityField(writer, &bytes);
}

fn writeIdentityField(writer: *std.Io.Writer, value: []const u8) !void {
    const value_len = std.math.cast(u64, value.len) orelse
        return error.InvalidPermissionIdentity;
    var length: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, &length, value_len, .big);
    try writer.writeAll(&length);
    try writer.writeAll(value);
}

fn interactivePermissionRequest(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    label_override: ?[]const u8,
) !permission_request.PermissionRequest {
    if (try isRunCommandCall(input, arena, call)) {
        const context = try runCommandContext(input, arena, call);
        if (label_override) |label| {
            return .{
                .label = label,
                .amendment_allowed = true,
            };
        }
        return .{
            .label = try tool_presentation.formatRunCommandPermissionLabel(
                arena,
                context.command,
            ),
            .command = try command_environment.formatApprovalCommand(
                arena,
                context.environment,
                context.command,
            ),
            .amendment_allowed = true,
        };
    }
    const runs_on_host = if (registeredTool(input, call.name)) |tool| tool.executor_kind == .host else false;
    const tool_arguments_preview = if (runs_on_host or isAvailableDynamicTool(input, call.name)) blk: {
        const encoded = try text_utils.encodeTerminalSafe(
            arena,
            call.arguments_json,
            permission_request.max_tool_arguments_preview_bytes,
        );
        break :blk encoded.bytes;
    } else null;
    return .{
        .label = label_override orelse try tool_presentation.formatPermissionLabel(
            arena,
            input.tool_registry,
            call,
        ),
        .tool_arguments_preview = tool_arguments_preview,
    };
}

fn formatVisionPathPermissionLabel(
    arena: Allocator,
    authority: command_admission.VisionPathExecutionAuthority,
) ![]const u8 {
    var label_len: usize = "vision ".len;
    for (authority.targets, 0..) |target, index| {
        if (index > 0) label_len = std.math.add(usize, label_len, ", ".len) catch
            return error.RequestProjectionTooLarge;
        label_len = std.math.add(usize, label_len, target.canonical_path.len) catch
            return error.RequestProjectionTooLarge;
        if (label_len > diff_mod.max_encoded_label_bytes) {
            return error.RequestProjectionTooLarge;
        }
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try out.writer.writeAll("vision ");
    for (authority.targets, 0..) |target, index| {
        if (index > 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(target.canonical_path);
    }
    return try out.toOwnedSlice();
}

fn noninteractivePermissionRequired(call: ToolCall, reason: []const u8) ToolPermissionDecision {
    debug_trace.logf(
        "core",
        "tool permission unavailable mode=headless approval_required=true reason={s} tool={s}",
        .{ reason, call.name },
    );
    return .permission_required;
}

pub fn permissionTargetResolutionFailureMessage(
    arena: Allocator,
    call: ToolCall,
    err: anyerror,
) !?[]const u8 {
    const reason: ?[]const u8 = switch (err) {
        error.FileNotFound => "Path not found",
        error.NotDir => "Path is not a directory",
        error.AccessDenied, error.PermissionDenied => "Access denied for path",
        error.PathOutsideWorkspace => "Path is outside the workspace",
        error.SymLinkLoop,
        error.NameTooLong,
        error.BadPathName,
        error.InputOutput,
        error.HomeNotSet,
        error.InvalidPath,
        error.WorkspaceUnavailable,
        => null,
        else => return null,
    };
    const path_arg = try targetPathForFailureMessage(arena, call);
    if (reason) |text| {
        return if (path_arg) |path|
            try arena.print("{s}: {s}", .{ text, path })
        else
            try arena.dupe(u8, text);
    }
    return if (path_arg) |path|
        try arena.print("Cannot resolve path \"{s}\": {s}", .{ path, @errorName(err) })
    else
        try arena.print("Cannot resolve tool target path: {s}", .{@errorName(err)});
}

fn targetPathForFailureMessage(arena: Allocator, call: ToolCall) !?[]const u8 {
    const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const is_file_tool = permissions.allowsExternalPath(call.name);
    const primary_key: []const u8 = if (is_file_tool) "path" else "cwd";
    const secondary_key: []const u8 = if (is_file_tool) "cwd" else "path";
    if (tool_args.optionalStringArg(args, primary_key)) |primary| {
        if (primary.len > 0) return primary;
    }
    if (tool_args.optionalStringArg(args, secondary_key)) |secondary| {
        if (secondary.len > 0) return secondary;
    }
    return null;
}

fn permissionTargetsForCall(input: Input, arena: Allocator, call: ToolCall) !permissions.PermissionCallTargets {
    if (isAvailableDynamicTool(input, call.name)) {
        const items = try arena.alloc(permissions.PermissionCallTarget, 1);
        items[0] = .{ .role = "target", .path = try arena.dupe(u8, call.name) };
        return .{ .items = items };
    }
    if (registeredWebSearchTarget(input, call.name)) |target_name| {
        const items = try arena.alloc(permissions.PermissionCallTarget, 1);
        errdefer arena.free(items);
        items[0] = .{
            .role = "target",
            .path = try arena.dupe(u8, target_name),
        };
        return .{ .items = items };
    }
    const tool = registeredTool(input, call.name) orelse return error.UnsupportedTool;
    if (try isRunCommandCall(input, arena, call)) {
        const items = try arena.alloc(permissions.PermissionCallTarget, 1);
        errdefer arena.free(items);
        items[0] = .{
            .role = "target",
            .path = try commandPermissionTarget(input, arena, call),
        };
        return .{ .items = items };
    }

    if (tool.executor_kind == .host) {
        const items = try arena.alloc(permissions.PermissionCallTarget, 1);
        errdefer arena.free(items);
        items[0] = .{ .role = "target", .path = try arena.dupe(u8, call.name) };
        return .{ .items = items };
    }
    var permission_call = call;
    if (std.mem.eql(u8, permission_call.name, "Bash")) {
        permission_call.name = "Bash";
    }
    return permissions.permissionTargetsForCallInScope(
        arena,
        accessScope(input),
        permission_call,
        tool.permission_target_kind,
    );
}

fn commandPermissionTarget(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) ![]u8 {
    const context = try runCommandContext(input, arena, call);
    const identity = try commandPermissionIdentityForContext(
        arena,
        context,
    );
    return arena.print(
        "{s}::{s}",
        .{ context.resolved_cwd, identity },
    );
}

fn sessionGrantsAllowAll(grants: []const PermissionGrant, tool_name: []const u8, targets: []const permissions.PermissionCallTarget) bool {
    for (targets) |target| {
        if (!permissions.sessionGrantAllowed(grants, tool_name, target.path)) return false;
    }
    return true;
}

pub fn permissionTargetForCall(input: Input, arena: Allocator, call: ToolCall) ![]const u8 {
    if (isAvailableDynamicTool(input, call.name)) return arena.dupe(u8, call.name);
    if (registeredWebSearchTarget(input, call.name)) |target_name| return arena.dupe(u8, target_name);
    const tool = registeredTool(input, call.name) orelse return error.UnsupportedTool;
    if (try isRunCommandCall(input, arena, call)) {
        return commandPermissionTarget(input, arena, call);
    }

    if (tool.executor_kind == .host) return arena.dupe(u8, call.name);
    return permissions.permissionTargetForCallInScope(
        arena,
        accessScope(input),
        call,
        tool.permission_target_kind,
    );
}

pub fn permissionTargetForLiveAuthority(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) ![]const u8 {
    return permissionTargetForCall(input, arena, call) catch |err| {
        if (!recoverableExistingPathResolutionFailure(err)) return err;
        const tool = registeredTool(input, call.name) orelse return err;
        if (tool.permission_target_kind != .path_existing) {
            return err;
        }
        return permissions.missingPathTargetForCallInScope(
            arena,
            accessScope(input),
            call,
        ) catch |fallback_err| {
            if (!recoverableExistingPathResolutionFailure(fallback_err)) {
                return fallback_err;
            }
            return permissions.unresolvedPathTargetForCallInScope(
                arena,
                accessScope(input),
                call,
            );
        };
    };
}

fn recoverableExistingPathResolutionFailure(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound,
        error.NotDir,
        error.AccessDenied,
        error.PermissionDenied,
        => true,
        else => false,
    };
}

fn isAvailableDynamicTool(input: Input, name: []const u8) bool {
    return tool_mcp_runtime.isAvailableDynamicTool(.{
        .is_registered_tool = registeredTool(input, name) != null,
        .advertised_dynamic_tool_names = input.advertised_dynamic_tool_names,
        .runtime = input.mcp_runtime,
    }, name);
}

test "permission target resolution reports a missing home" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const failure = (try permissionTargetResolutionFailureMessage(
        arena,
        .{ .id = "read_missing_home", .name = "read_file", .arguments_json = "{\"path\":\"~/missing\"}" },
        error.HomeNotSet,
    )).?;
    try std.testing.expect(std.mem.find(u8, failure, "HomeNotSet") != null);
    try std.testing.expect(std.mem.find(u8, failure, "~/missing") != null);
}

test "permission target failures name the unresolved path without hiding runtime errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call: ToolCall = .{
        .id = "grep_missing",
        .name = "grep_files",
        .arguments_json = "{\"pattern\":\"x\",\"path\":\"missing/dir\"}",
    };
    const not_found = (try permissionTargetResolutionFailureMessage(arena, call, error.FileNotFound)).?;
    try std.testing.expectEqualStrings("Path not found: missing/dir", not_found);

    const arm_cases = [_]struct { err: anyerror, expected: []const u8 }{
        .{ .err = error.NotDir, .expected = "Path is not a directory: missing/dir" },
        .{ .err = error.AccessDenied, .expected = "Access denied for path: missing/dir" },
        .{ .err = error.PermissionDenied, .expected = "Access denied for path: missing/dir" },
        .{ .err = error.PathOutsideWorkspace, .expected = "Path is outside the workspace: missing/dir" },
        .{ .err = error.SymLinkLoop, .expected = "Cannot resolve path \"missing/dir\": SymLinkLoop" },
        .{ .err = error.NameTooLong, .expected = "Cannot resolve path \"missing/dir\": NameTooLong" },
    };
    for (arm_cases) |case| {
        const failure = (try permissionTargetResolutionFailureMessage(arena, call, case.err)) orelse return error.TestExpectedToolFailure;
        try std.testing.expectEqualStrings(case.expected, failure);
    }

    const command_call: ToolCall = .{
        .id = "command_missing_cwd",
        .name = "run_command",
        .arguments_json = "{\"command\":\"ls\",\"cwd\":\"gone/dir\"}",
    };
    const cwd_failure = (try permissionTargetResolutionFailureMessage(arena, command_call, error.FileNotFound)).?;
    try std.testing.expectEqualStrings("Path not found: gone/dir", cwd_failure);

    const mixed_command_call: ToolCall = .{
        .id = "command_both_keys",
        .name = "Bash",
        .arguments_json = "{\"command\":\"ls\",\"path\":\"decoy\",\"cwd\":\"gone/dir\"}",
    };
    const mixed_command_failure = (try permissionTargetResolutionFailureMessage(arena, mixed_command_call, error.FileNotFound)).?;
    try std.testing.expectEqualStrings("Path not found: gone/dir", mixed_command_failure);

    const mixed_file_call: ToolCall = .{
        .id = "file_both_keys",
        .name = "read_file",
        .arguments_json = "{\"path\":\"missing/dir\",\"cwd\":\"decoy\"}",
    };
    const mixed_file_failure = (try permissionTargetResolutionFailureMessage(arena, mixed_file_call, error.FileNotFound)).?;
    try std.testing.expectEqualStrings("Path not found: missing/dir", mixed_file_failure);

    const no_path_call: ToolCall = .{ .id = "no_path", .name = "grep_files", .arguments_json = "{\"pattern\":\"x\"}" };
    const bare_failure = (try permissionTargetResolutionFailureMessage(arena, no_path_call, error.FileNotFound)).?;
    try std.testing.expectEqualStrings("Path not found", bare_failure);

    for ([_]anyerror{ error.OutOfMemory, error.Cancelled, error.HostAuthorityUnavailable }) |err| {
        try std.testing.expectEqual(null, try permissionTargetResolutionFailureMessage(arena, call, err));
    }
}

test "interactive terminal exec approval permits command amendments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    const input: Input = .{
        .workspace_root = "/tmp/workspace",
        .permission_grants = &.{},
        .permission_rules = .{},
        .tool_registry = test_admission_registry,
        .worker = &worker,
        .advertised_dynamic_tool_names = &.{},
        .mcp_runtime = .{},
    };

    const foreground = try interactivePermissionRequest(input, arena_state.allocator(), .{
        .id = "foreground",
        .name = "Bash",
        .arguments_json = "{\"command\":\"printf foreground\"}",
    }, null);
    try std.testing.expect(foreground.amendment_allowed);
}

test "interactive command approval keeps activity projection out of permission request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    const input: Input = .{
        .workspace_root = "/tmp/workspace",
        .permission_grants = &.{},
        .permission_rules = .{},
        .tool_registry = test_admission_registry,
        .worker = &worker,
        .advertised_dynamic_tool_names = &.{},
        .mcp_runtime = .{},
    };
    const raw_command = "cat <<'EOF'\nline one\nEOF";
    const call: ToolCall = .{
        .id = "multiline",
        .name = "Bash",
        .arguments_json = "{\"command\":\"cat <<'EOF'\\nline one\\nEOF\"}",
    };

    const activity = (try tool_presentation.formatRunCommandActivity(
        arena,
        input.tool_registry,
        input.workspace_root,
        call,
    )) orelse return error.TestExpectedEqual;
    defer arena.free(activity.detail);
    try std.testing.expectEqualStrings("cat <<'EOF' line one EOF", activity.detail);

    const request = try interactivePermissionRequest(input, arena, call, null);
    try std.testing.expectEqualStrings(
        "shell.run cat <<'EOF'\\x0aline one\\x0aEOF",
        request.label,
    );
    const approval_command = request.command orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.startsWith(
        u8,
        approval_command,
        "# shell.run profile=user shell=",
    ));
    try std.testing.expect(std.mem.endsWith(u8, approval_command, "\n" ++ raw_command));
}

test "terminal exec timeout and profile omission share user grants while clean stays isolated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    const input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );

    const omitted = try permissionTargetForCall(input, arena, .{
        .id = "omitted",
        .name = "Bash",
        .arguments_json = "{\"command\":\"printf scoped\",\"timeout_ms\":1}",
    });
    const clean = permissionTargetForCall(input, arena, .{
        .id = "clean",
        .name = "Bash",
        .arguments_json = "{\"command\":\"printf scoped\",\"profile\":\"clean\",\"timeout_ms\":5000}",
    }) catch |err| switch (err) {
        error.MissingLoginShell, error.UnsupportedShell => return error.SkipZigTest,
        else => return err,
    };
    const user = try permissionTargetForCall(input, arena, .{
        .id = "user",
        .name = "Bash",
        .arguments_json = "{\"command\":\"printf scoped\",\"profile\":\"user\",\"timeout_ms\":600000}",
    });

    try std.testing.expectEqualStrings(omitted, user);
    try std.testing.expect(!std.mem.eql(u8, omitted, clean));
    try std.testing.expect(!std.mem.eql(u8, clean, user));
    const grants = try permissions.suggestedSessionGrants(
        arena,
        input.workspace_root,
        "run_command",
        clean,
        .command_cwd,
    );
    try std.testing.expect(permissions.sessionGrantAllowed(grants, "run_command", clean));
    try std.testing.expect(!permissions.sessionGrantAllowed(grants, "run_command", user));
    try std.testing.expect(!permissions.sessionGrantAllowed(grants, "run_command", omitted));

    const request = try interactivePermissionRequest(input, arena, .{
        .id = "user-prompt",
        .name = "Bash",
        .arguments_json = "{\"command\":\"printf scoped\",\"profile\":\"user\"}",
    }, null);
    const approval_command = request.command orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.startsWith(
        u8,
        approval_command,
        "# shell.run profile=user shell=",
    ));
    try std.testing.expect(std.mem.endsWith(
        u8,
        approval_command,
        "\nprintf scoped",
    ));
}

test "interactive command approval keeps dangerous-command guidance" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    const input: Input = .{
        .workspace_root = "/tmp/workspace",
        .permission_grants = &.{},
        .permission_rules = .{},
        .tool_registry = test_admission_registry,
        .worker = &worker,
        .advertised_dynamic_tool_names = &.{},
        .mcp_runtime = .{},
    };

    const request = try interactivePermissionRequest(input, arena_state.allocator(), .{
        .id = "dangerous",
        .name = "Bash",
        .arguments_json = "{\"command\":\"git reset --hard\"}",
    }, null);

    try std.testing.expect(std.mem.find(u8, request.label, "risk: command may discard version-control state") != null);
    try std.testing.expect(std.mem.find(u8, request.label, "safer: inspect git status first") != null);
}

test "plan mode refuses mutating calls at admission and runs read-only ones" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var state: plan_mode.State = .{};
    state.set(true);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.plan_mode = &state;
    input.tool_registry = .{ .tools = &.{ test_builtin_tools.write_file, test_builtin_tools.read_file } };

    const refused = try requestPermissionOutcome(input, arena, .{
        .id = "write-in-plan",
        .name = "write_file",
        .arguments_json = "{\"path\":\"notes.md\",\"content\":\"draft\"}",
    }, .yolo, &.{});
    try std.testing.expectEqualStrings(
        "Plan mode is active. You may only write to the current plan file: /tmp/workspace/.fx/plans/plan.md. Call ExitPlanMode to exit plan mode before editing other files.",
        refused.tool_failure.?,
    );

    const read = try planModeOutcome(input, arena, .{
        .id = "read-in-plan",
        .name = "read_file",
        .arguments_json = "{\"path\":\"notes.md\"}",
    });
    try std.testing.expect(read == null);

    state.set(false);
    const inactive = try planModeOutcome(input, arena, .{
        .id = "write-after-plan",
        .name = "write_file",
        .arguments_json = "{\"path\":\"notes.md\",\"content\":\"draft\"}",
    });
    try std.testing.expect(inactive == null);
}

test "plan mode sends ExitPlanMode to the user prompt and fails closed without one" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var state: plan_mode.State = .{};
    state.set(true);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.plan_mode = &state;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.exit_plan_mode} };
    const exit_call: ToolCall = .{ .id = "exit-plan", .name = "ExitPlanMode", .arguments_json = "{\"plan\":\"Edit the parser.\"}" };

    const unattended = try requestPermissionOutcome(input, arena, exit_call, .yolo, &.{});
    try std.testing.expectEqualStrings(plan_mode.exit_requires_prompt_message, unattended.tool_failure.?);

    var recording = RecordingPrompter{ .decision = .deny };
    input.permission_prompter = recording.prompter();
    const denied = try requestPermissionOutcome(input, arena, exit_call, .yolo, &.{});
    try std.testing.expectEqualStrings(plan_mode.approval_label, recording.last_label.?);
    try std.testing.expectEqualStrings("Edit the parser.", recording.last_command.?);
    try std.testing.expect(recording.last_amendment_allowed);
    try std.testing.expect(denied.decision.isDenied());
    try std.testing.expectEqualStrings("Plan rejected by user. Plan mode remains active.", denied.tool_failure.?);
    try std.testing.expect(state.isActive());
    try std.testing.expect(state.takeReview() == null);

    recording.decision = .always;
    const approved = try requestPermissionOutcome(input, arena, exit_call, .yolo, &.{});
    try std.testing.expect(approved.tool_failure == null);
    try std.testing.expect(!approved.decision.isDenied());
    try std.testing.expectEqual(@as(usize, 2), recording.calls);
    try std.testing.expectEqual(plan_mode.ReviewVerdict.approved, state.takeReview().?.verdict);
}

test "plan review hands revision feedback and a dismissal to the ExitPlanMode result without leaving plan mode" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var state: plan_mode.State = .{};
    state.set(true);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.plan_mode = &state;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.exit_plan_mode} };
    const exit_call: ToolCall = .{ .id = "exit-plan", .name = "ExitPlanMode", .arguments_json = "{\"plan\":\"Edit the parser.\"}" };

    var recording = RecordingPrompter{ .decision = .deny, .feedback = "cover the tokenizer too" };
    input.permission_prompter = recording.prompter();
    const revised = try requestPermissionOutcome(input, arena, exit_call, .ask, &.{});
    try std.testing.expect(revised.tool_failure == null);
    try std.testing.expect(!revised.decision.isDenied());
    try std.testing.expect(revised.feedback == null);
    const revise_review = state.takeReview().?;
    try std.testing.expectEqual(plan_mode.ReviewVerdict.revise, revise_review.verdict);
    try std.testing.expectEqualStrings("cover the tokenizer too", revise_review.feedback().?);

    recording.feedback = null;
    recording.plan_review = .revise;
    _ = try requestPermissionOutcome(input, arena, exit_call, .ask, &.{});
    const unexplained_review = state.takeReview().?;
    try std.testing.expectEqual(plan_mode.ReviewVerdict.revise, unexplained_review.verdict);
    try std.testing.expect(unexplained_review.feedback() == null);

    recording.plan_review = .dismissed;
    const dismissed = try requestPermissionOutcome(input, arena, exit_call, .ask, &.{});
    try std.testing.expect(dismissed.tool_failure == null);
    try std.testing.expect(!dismissed.decision.isDenied());
    try std.testing.expectEqual(plan_mode.ReviewVerdict.dismissed, state.takeReview().?.verdict);

    recording.plan_review = .reject;
    const rejected = try requestPermissionOutcome(input, arena, exit_call, .ask, &.{});
    try std.testing.expectEqualStrings(plan_mode.rejected_message, rejected.tool_failure.?);
    try std.testing.expect(state.takeReview() == null);
    try std.testing.expect(state.isActive());
}

test "plan review reads the plan file when the call carries no plan and names the file when it is empty" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var state: plan_mode.State = .{};
    state.set(true);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.workspace_root = workspace;
    input.plan_mode = &state;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.exit_plan_mode} };
    var recording = RecordingPrompter{ .decision = .once };
    input.permission_prompter = recording.prompter();
    const exit_call: ToolCall = .{ .id = "exit-plan", .name = "ExitPlanMode", .arguments_json = "{}" };

    const missing = try requestPermissionOutcome(input, arena, exit_call, .ask, &.{});
    const expected_missing = try arena.print(
        "No plan file found. Write your plan to {s}/.fx/plans/plan.md first, then call ExitPlanMode.",
        .{workspace},
    );
    try std.testing.expectEqualStrings(expected_missing, missing.tool_failure.?);
    try std.testing.expectEqual(@as(usize, 0), recording.calls);

    const path = try plan_mode.preparePlanFile(arena, workspace);
    try io_mod.writeFileAtomic(arena, path, "1. Edit the parser.\n");
    const approved = try requestPermissionOutcome(input, arena, exit_call, .ask, &.{});
    try std.testing.expect(approved.tool_failure == null);
    try std.testing.expectEqualStrings("1. Edit the parser.", recording.last_command.?);
}

test "plan mode lets write_file and edit_file reach the plan file without a prompt and refuses other files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var state: plan_mode.State = .{};
    state.set(true);
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.workspace_root = workspace;
    input.plan_mode = &state;
    input.permission_prompter = recording.prompter();

    const spellings = [_][]const u8{
        "{\"path\":\".fx/plans/plan.md\",\"content\":\"1. Edit the parser.\\n\"}",
        "{\"path\":\"./.fx/plans/plan.md\",\"content\":\"1. Edit the parser.\\n\"}",
        try arena.print("{{\"path\":\"{s}/.fx/plans/plan.md\",\"content\":\"1. Edit the parser.\\n\"}}", .{workspace}),
    };
    for (spellings) |arguments_json| {
        const plan_write: ToolCall = .{ .id = "plan-write", .name = "write_file", .arguments_json = arguments_json };
        try std.testing.expect((try planModeOutcome(input, arena, plan_write)) == null);
        try std.testing.expectEqual(PermissionMode.auto, planFileWriteMode(input, arena, plan_write, .ask));
    }
    _ = try plan_mode.preparePlanFile(arena, workspace);
    const admitted = try requestPermissionOutcome(input, arena, .{
        .id = "plan-write",
        .name = "write_file",
        .arguments_json = spellings[2],
    }, .ask, &.{});
    try std.testing.expect(admitted.tool_failure == null);
    try std.testing.expectEqual(ToolPermissionDecision.once, admitted.decision);
    try std.testing.expectEqual(@as(usize, 0), recording.calls);

    const other_write: ToolCall = .{
        .id = "other-write",
        .name = "write_file",
        .arguments_json = "{\"path\":\".fx/plans/other.md\",\"content\":\"draft\"}",
    };
    const refused = try requestPermissionOutcome(input, arena, other_write, .ask, &.{});
    const expected_refusal = try arena.print(
        "Plan mode is active. You may only write to the current plan file: {s}/.fx/plans/plan.md. Call ExitPlanMode to exit plan mode before editing other files.",
        .{workspace},
    );
    try std.testing.expectEqualStrings(expected_refusal, refused.tool_failure.?);
    try std.testing.expectEqual(PermissionMode.ask, planFileWriteMode(input, arena, other_write, .ask));

    state.set(false);
    const plan_write_outside_plan_mode: ToolCall = .{ .id = "plan-write", .name = "write_file", .arguments_json = spellings[0] };
    try std.testing.expectEqual(PermissionMode.ask, planFileWriteMode(input, arena, plan_write_outside_plan_mode, .ask));
}

test "plan approval offers the model options and reports the chosen one" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var state: plan_mode.State = .{};
    state.set(true);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.plan_mode = &state;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.exit_plan_mode} };
    const exit_call: ToolCall = .{
        .id = "exit-plan",
        .name = "ExitPlanMode",
        .arguments_json = "{\"plan\":\"Edit the parser.\",\"options\":[{\"label\":\"Ship it\"},{\"label\":\"Split work\"}]}",
    };
    var recording = RecordingPrompter{ .decision = .once, .selected_option = 1 };
    input.permission_prompter = recording.prompter();
    const outcome = try requestPermissionOutcome(input, arena, exit_call, .yolo, &.{});
    try std.testing.expectEqual(@as(usize, 2), recording.last_choice_count);
    try std.testing.expect(!outcome.decision.isDenied());
    try std.testing.expect(outcome.feedback == null);
    const review = state.takeReview().?;
    try std.testing.expectEqual(plan_mode.ReviewVerdict.approved, review.verdict);
    try std.testing.expectEqualStrings("Split work", review.selectedOption().?);
    try std.testing.expect(review.savedLocation() == null);
}

test "CreateGoal shows the goal start prompt in ask and yolo and runs when a start row is picked" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.tool_registry = .{ .tools = &.{@import("../../tools/goal/goal.zig").create_goal} };
    const goal_call: ToolCall = .{
        .id = "create-goal",
        .name = "CreateGoal",
        .arguments_json = "{\"objective\":\"ship the parser\",\"completionCriterion\":\"tests pass\"}",
    };

    var manual = RecordingPrompter{ .decision = .once, .selected_option = 0 };
    input.permission_prompter = manual.prompter();
    const manual_outcome = try requestPermissionOutcome(input, arena, goal_call, .ask, &.{});
    try std.testing.expectEqual(@as(usize, 1), manual.calls);
    try std.testing.expectEqualStrings("Start a goal with approvals on?", manual.last_label.?);
    try std.testing.expectEqual(@as(usize, 1), manual.last_choice_count);
    try std.testing.expect(!manual.last_amendment_allowed);
    try std.testing.expectEqualStrings("Start goal: ship the parser · Done when: tests pass", manual.last_explanation.?);
    try std.testing.expect(!manual_outcome.decision.isDenied());
    try std.testing.expect(manual_outcome.tool_failure == null);

    var yolo = RecordingPrompter{ .decision = .once, .selected_option = 1 };
    input.permission_prompter = yolo.prompter();
    const yolo_outcome = try requestPermissionOutcome(input, arena, goal_call, .yolo, &.{});
    try std.testing.expectEqual(@as(usize, 1), yolo.calls);
    try std.testing.expectEqualStrings("Start a goal in Ask When Needed mode?", yolo.last_label.?);
    try std.testing.expectEqual(@as(usize, 0), yolo.last_choice_count);
    try std.testing.expect(!yolo_outcome.decision.isDenied());
}

test "declining the goal start prompt returns Kimi's cancelled text and does not run CreateGoal" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.tool_registry = .{ .tools = &.{@import("../../tools/goal/goal.zig").create_goal} };
    const goal_call: ToolCall = .{
        .id = "create-goal",
        .name = "CreateGoal",
        .arguments_json = "{\"objective\":\"ship the parser\"}",
    };
    const cancelled = "Tool \"CreateGoal\" was not run because the approval request was cancelled.";

    var do_not_start = RecordingPrompter{ .decision = .deny, .selected_option = 3 };
    input.permission_prompter = do_not_start.prompter();
    const row_outcome = try requestPermissionOutcome(input, arena, goal_call, .ask, &.{});
    try std.testing.expect(row_outcome.decision.isDenied());
    try std.testing.expectEqualStrings(cancelled, row_outcome.tool_failure.?);
    try std.testing.expectEqualStrings("Start goal: ship the parser", do_not_start.last_explanation.?);

    var yolo_row = RecordingPrompter{ .decision = .once, .selected_option = 2 };
    input.permission_prompter = yolo_row.prompter();
    const yolo_outcome = try requestPermissionOutcome(input, arena, goal_call, .yolo, &.{});
    try std.testing.expect(yolo_outcome.decision.isDenied());
    try std.testing.expectEqualStrings(cancelled, yolo_outcome.tool_failure.?);

    var escaped = RecordingPrompter{ .decision = .deny };
    input.permission_prompter = escaped.prompter();
    const escaped_outcome = try requestPermissionOutcome(input, arena, goal_call, .ask, &.{});
    try std.testing.expect(escaped_outcome.decision.isDenied());
    try std.testing.expectEqualStrings(cancelled, escaped_outcome.tool_failure.?);
}

test "CreateGoal skips the goal start prompt in auto, in dontAsk and without a prompter" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.tool_registry = .{ .tools = &.{@import("../../tools/goal/goal.zig").create_goal} };
    const goal_call: ToolCall = .{
        .id = "create-goal",
        .name = "CreateGoal",
        .arguments_json = "{\"objective\":\"ship the parser\"}",
    };

    var recording = RecordingPrompter{ .decision = .deny };
    input.permission_prompter = recording.prompter();
    for ([_]PermissionMode{ .auto, .dontAsk }) |mode| {
        const outcome = try requestPermissionOutcome(input, arena, goal_call, mode, &.{});
        try std.testing.expect(!outcome.decision.isDenied());
    }
    try std.testing.expectEqual(@as(usize, 0), recording.calls);

    input.permission_prompter = null;
    for ([_]PermissionMode{ .ask, .yolo }) |mode| {
        const outcome = try requestPermissionOutcome(input, arena, goal_call, mode, &.{});
        try std.testing.expect(!outcome.decision.isDenied());
        try std.testing.expect(outcome.tool_failure == null);
    }
}

test "approved plan is saved and the approval reports where it went" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var state: plan_mode.State = .{};
    state.set(true);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.plan_mode = &state;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.exit_plan_mode} };
    var saver_state = RecordingPlanSaver{};
    input.plan_saver = saver_state.saver();
    const exit_call: ToolCall = .{
        .id = "exit-plan",
        .name = "ExitPlanMode",
        .arguments_json = "{\"plan\":\"Edit the parser.\"}",
    };
    var recording = RecordingPrompter{ .decision = .once };
    input.permission_prompter = recording.prompter();
    const outcome = try requestPermissionOutcome(input, arena, exit_call, .yolo, &.{});
    try std.testing.expectEqualStrings("Edit the parser.", saver_state.saved_text);
    try std.testing.expect(outcome.feedback == null);
    const review = state.takeReview().?;
    try std.testing.expectEqualStrings("plan-test.md", review.savedLocation().?);
    try std.testing.expect(review.selectedOption() == null);

    saver_state.saved_text = "";
    recording.decision = .deny;
    _ = try requestPermissionOutcome(input, arena, exit_call, .yolo, &.{});
    try std.testing.expectEqualStrings("", saver_state.saved_text);
}

const RecordingPlanSaver = struct {
    saved_text: []const u8 = "",

    fn saver(self: *RecordingPlanSaver) PlanSaver {
        return .{ .context = self, .save_fn = save };
    }

    fn save(context: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8 {
        const self: *RecordingPlanSaver = @ptrCast(@alignCast(context));
        self.saved_text = try arena.dupe(u8, text);
        return "plan-test.md";
    }
};

test "interactive Vision path approval names every canonical image" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (.{ "first.png", "second.png" }) |name| {
        var file = try tmp.dir.createFile(std.testing.io, name, .{});
        file.close(std.testing.io);
    }
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const first = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "first.png");
    defer alloc.free(first);
    const second = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "second.png");
    defer alloc.free(second);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.workspace_root = workspace;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.vision} };
    var recording = RecordingPrompter{};
    input.permission_prompter = recording.prompter();

    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "vision-paths",
            .name = "vision",
            .arguments_json = "{\"paths\":[\"first.png\",\"second.png\"],\"focus\":\"compare\"}",
        },
        .ask,
        &.{},
    );
    const expected = try alloc.print("vision {s}, {s}", .{ first, second });
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, recording.last_label.?);
    const authority = switch (outcome.execution_authority orelse
        return error.TestExpectedEqual) {
        .vision_paths => |value| value,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(@as(usize, 2), authority.targets.len);
    try std.testing.expectEqualStrings(first, authority.targets[0].canonical_path);
    try std.testing.expectEqualStrings(second, authority.targets[1].canonical_path);
}

test "Vision path admission returns a tool failure for directories" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.workspace_root = workspace;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.vision} };

    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "vision-directory",
            .name = "vision",
            .arguments_json = "{\"paths\":[\".\"],\"focus\":\"inspect\"}",
        },
        .yolo,
        &.{},
    );
    try std.testing.expect(outcome.execution_authority == null);
    try std.testing.expectEqualStrings(
        "Vision paths must reference regular files.",
        outcome.tool_failure orelse return error.TestExpectedEqual,
    );
}

test "Vision path admission retains the canonical execution targets" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (.{ "target-a.png", "target-b.png" }) |name| {
        var file = try tmp.dir.createFile(std.testing.io, name, .{});
        file.close(std.testing.io);
    }
    try tmp.dir.symLink(
        std.testing.io,
        "target-a.png",
        "approved.png",
        .{ .is_directory = false },
    );
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const target_a = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "target-a.png");
    defer alloc.free(target_a);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.workspace_root = workspace;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.vision} };

    const call: ToolCall = .{
        .id = "vision-bound-path",
        .name = "vision",
        .arguments_json = "{\"paths\":[\"approved.png\"],\"focus\":\"inspect\"}",
    };
    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .yolo,
        &.{},
    );
    const authority = switch (outcome.execution_authority orelse
        return error.TestExpectedEqual) {
        .vision_paths => |value| value,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(@as(usize, 1), authority.targets.len);
    try std.testing.expectEqualStrings(target_a, authority.targets[0].canonical_path);

    try tmp.dir.deleteFile(std.testing.io, "approved.png");
    try tmp.dir.symLink(
        std.testing.io,
        "target-b.png",
        "approved.png",
        .{ .is_directory = false },
    );
    try std.testing.expectEqualStrings(target_a, authority.targets[0].canonical_path);

    const revalidated = try revalidateLiveActionPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .ask,
        &.{},
        outcome.execution_authority.?,
        .once,
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, revalidated.decision);
    const revalidated_authority = switch (revalidated.execution_authority orelse
        return error.TestExpectedEqual) {
        .vision_paths => |value| value,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expectEqualStrings(
        target_a,
        revalidated_authority.targets[0].canonical_path,
    );

    try tmp.dir.deleteFile(std.testing.io, "target-a.png");
    try tmp.dir.symLink(
        std.testing.io,
        "target-b.png",
        "target-a.png",
        .{ .is_directory = false },
    );
    const replaced = try revalidateLiveActionPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .ask,
        &.{},
        outcome.execution_authority.?,
        .once,
    );
    try std.testing.expect(replaced.decision.isDenied());
    try std.testing.expect(replaced.execution_authority == null);
}

test "dynamic MCP admission checks built-in and advertised names before runtime lookup" {
    const CountingMcp = struct {
        calls: usize = 0,

        fn hasTool(raw_ctx: *anyopaque, _: []const u8, _: tool_mcp_runtime.Access) bool {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx));
            self.calls += 1;
            return true;
        }
    };

    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var mcp = CountingMcp{};
    const advertised = [_][]const u8{"mcp_example"};
    const input: Input = .{
        .workspace_root = "/tmp/workspace",
        .permission_grants = &.{},
        .permission_rules = .{},
        .worker = &worker,
        .tool_registry = test_admission_registry,
        .advertised_dynamic_tool_names = &advertised,
        .mcp_runtime = .{
            .context = @ptrCast(&mcp),
            .has_tool = CountingMcp.hasTool,
        },
    };

    try std.testing.expect(!isAvailableDynamicTool(input, "glob_files"));
    try std.testing.expect(!isAvailableDynamicTool(input, "mcp_unadvertised"));
    try std.testing.expectEqual(@as(usize, 0), mcp.calls);
    try std.testing.expect(isAvailableDynamicTool(input, "mcp_example"));
    try std.testing.expectEqual(@as(usize, 1), mcp.calls);
}

test "interactive dynamic MCP approval projects bounded terminal-safe arguments only" {
    const AvailableMcp = struct {
        fn hasTool(_: *anyopaque, _: []const u8, _: tool_mcp_runtime.Access) bool {
            return true;
        }
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var mcp: u8 = 0;
    const advertised = [_][]const u8{"mcp_example"};
    const input: Input = .{
        .workspace_root = "/tmp/workspace",
        .permission_grants = &.{},
        .permission_rules = .{},
        .worker = &worker,
        .tool_registry = test_admission_registry,
        .advertised_dynamic_tool_names = &advertised,
        .mcp_runtime = .{
            .context = @ptrCast(&mcp),
            .has_tool = AvailableMcp.hasTool,
        },
    };

    const request = try interactivePermissionRequest(input, arena, .{
        .id = "dynamic",
        .name = "mcp_example",
        .arguments_json = "{\"text\":\"line\\n\x1b[31m\"}",
    }, null);
    try std.testing.expectEqualStrings(
        "{\"text\":\"line\\n\\x1b[31m\"}",
        request.tool_arguments_preview.?,
    );

    const non_dynamic = try interactivePermissionRequest(input, arena, .{
        .id = "builtin",
        .name = "glob_files",
        .arguments_json = "{\"pattern\":\"*\"}",
    }, null);
    try std.testing.expectEqual(@as(?[]const u8, null), non_dynamic.tool_arguments_preview);

    const oversized = try arena.alloc(
        u8,
        permission_request.max_tool_arguments_preview_bytes + 1,
    );
    @memset(oversized, 'x');
    const bounded = try interactivePermissionRequest(input, arena, .{
        .id = "bounded",
        .name = "mcp_example",
        .arguments_json = oversized,
    }, null);
    try std.testing.expectEqual(
        permission_request.max_tool_arguments_preview_bytes,
        bounded.tool_arguments_preview.?.len,
    );
    try std.testing.expect(std.mem.endsWith(
        u8,
        bounded.tool_arguments_preview.?,
        "...",
    ));
}

test "file mutation preflight reports malformed input before authority construction" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    file_mutation_decode_count = 0;
    const outcome = try preflightFileMutation(arena_state.allocator(), .{
        .id = "malformed",
        .name = "write_file",
        .arguments_json = "{",
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = "/tmp/workspace",
        .permission_rules = .{},
        .permission_mode = .auto,
        .can_prompt = false,
    });
    try std.testing.expectEqual(@as(std.meta.Tag(FileMutationPreflight), .tool_failure), std.meta.activeTag(outcome));
    try std.testing.expectEqual(@as(usize, 1), file_mutation_decode_count);
}

test "prepared file mutation admission decodes and resolves exactly once without legacy checks" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.workspace_root = workspace;
    const call: ToolCall = .{
        .id = "prepared-write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"nested/file.txt\",\"content\":\"hello\\n\"}",
    };

    file_mutation_decode_count = 0;
    file_mutation_resolution_count = 0;
    file_mutation.resetTargetResolutionCheckCountForTest();
    var prepared = switch (try prepareFileMutationCall(arena, call, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .not_file_mutation => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer prepared.deinit(arena);

    const expected_target = try std.Io.Dir.path.join(arena, &.{ workspace, "nested", "file.txt" });
    try std.testing.expectEqualStrings(expected_target, prepared.targetPath());
    try std.testing.expect(prepared.targets.proofValid());
    try std.testing.expectEqual(@as(usize, 1), file_mutation_decode_count);
    try std.testing.expectEqual(@as(usize, 1), file_mutation_resolution_count);

    const outcome = try resolvePreparedFileMutationAdmission(
        input,
        arena,
        call,
        &prepared,
        .ask,
        &.{},
    );
    const authorization = switch (outcome) {
        .prompt => |pending| pending.authorization,
        else => return error.TestExpectedPermissionRequired,
    };
    try std.testing.expect(authorization.prepared != null);
    try std.testing.expectEqualStrings("nested/file.txt", authorization.input.path());
    try std.testing.expectEqual(@as(usize, 1), file_mutation_decode_count);
    try std.testing.expectEqual(@as(usize, 1), file_mutation_resolution_count);
    try std.testing.expectEqual(@as(usize, 0), file_mutation.targetResolutionCheckCountForTest());
}

test "external file action identity is canonical across call IDs and distinguishes changed content" {
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
    const absolute_target = try std.Io.Dir.path.join(
        arena,
        &.{ external, "denied", "nested", "file.txt" },
    );
    const absolute_arguments = try arena.print(
        "{{\"path\":\"{s}\",\"content\":\"denied\\n\"}}",
        .{absolute_target},
    );
    const relative_arguments =
        "{\"content\":\"denied\\n\",\"path\":\"../external/denied/nested/file.txt\"}";
    const changed_arguments =
        "{\"path\":\"../external/denied/nested/file.txt\",\"content\":\"changed\\n\"}";

    var first = switch (try prepareFileMutationCall(arena, .{
        .id = "first-call-id",
        .name = "write_file",
        .arguments_json = absolute_arguments,
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .not_file_mutation => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer first.deinit(arena);
    var equivalent = switch (try prepareFileMutationCall(arena, .{
        .id = "different-call-id",
        .name = "write_file",
        .arguments_json = relative_arguments,
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .not_file_mutation => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer equivalent.deinit(arena);
    var changed = switch (try prepareFileMutationCall(arena, .{
        .id = "changed-call-id",
        .name = "write_file",
        .arguments_json = changed_arguments,
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .not_file_mutation => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer changed.deinit(arena);

    const first_identity = first.externalActionIdentity() orelse
        return error.TestExpectedExternalAction;
    const equivalent_identity = equivalent.externalActionIdentity() orelse
        return error.TestExpectedExternalAction;
    const changed_identity = changed.externalActionIdentity() orelse
        return error.TestExpectedExternalAction;
    try std.testing.expect(first_identity.eql(equivalent_identity));
    try std.testing.expect(!first_identity.eql(changed_identity));
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(
            std.testing.io,
            try std.Io.Dir.path.join(arena, &.{ external, "denied" }),
            .{},
        ),
    );
}

test "external file action identity distinguishes append from overwrite of the same content" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var overwrite = switch (try prepareFileMutationCall(arena, .{
        .id = "overwrite-call-id",
        .name = "write_file",
        .arguments_json = "{\"path\":\"../external/file.txt\",\"content\":\"same\\n\"}",
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .not_file_mutation => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer overwrite.deinit(arena);
    var append = switch (try prepareFileMutationCall(arena, .{
        .id = "append-call-id",
        .name = "write_file",
        .arguments_json = "{\"path\":\"../external/file.txt\",\"content\":\"same\\n\",\"mode\":\"append\"}",
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .not_file_mutation => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer append.deinit(arena);

    const overwrite_identity = overwrite.externalActionIdentity() orelse
        return error.TestExpectedExternalAction;
    const append_identity = append.externalActionIdentity() orelse
        return error.TestExpectedExternalAction;
    try std.testing.expect(!overwrite_identity.eql(append_identity));
}

test "external edit action identity distinguishes replace_all from a single replacement" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "external/file.txt", .data = "a\n" });
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var single = switch (try prepareFileMutationCall(arena, .{
        .id = "single-edit-call-id",
        .name = "edit_file",
        .arguments_json = "{\"path\":\"../external/file.txt\",\"old_string\":\"a\",\"new_string\":\"b\"}",
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .not_file_mutation => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer single.deinit(arena);
    var every = switch (try prepareFileMutationCall(arena, .{
        .id = "replace-all-call-id",
        .name = "edit_file",
        .arguments_json = "{\"path\":\"../external/file.txt\",\"old_string\":\"a\",\"new_string\":\"b\",\"replace_all\":true}",
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .not_file_mutation => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer every.deinit(arena);

    const single_identity = single.externalActionIdentity() orelse
        return error.TestExpectedExternalAction;
    const every_identity = every.externalActionIdentity() orelse
        return error.TestExpectedExternalAction;
    try std.testing.expect(!single_identity.eql(every_identity));
}

test "prepared file mutation rejects a changed call without decoding or resolving again" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const original: ToolCall = .{
        .id = "bound-write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"original.txt\",\"content\":\"original\"}",
    };

    file_mutation_decode_count = 0;
    file_mutation_resolution_count = 0;
    var prepared = switch (try prepareFileMutationCall(arena, original, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .not_file_mutation => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer prepared.deinit(arena);

    const outcome = try preflightPreparedFileMutation(arena, .{
        .id = original.id,
        .name = original.name,
        .arguments_json = "{\"path\":\"changed.txt\",\"content\":\"changed\"}",
    }, &prepared, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
        .permission_rules = .{},
        .permission_mode = .auto,
        .can_prompt = false,
    });
    const reason = switch (outcome) {
        .tool_failure => |value| value,
        else => return error.TestExpectedToolFailure,
    };
    try std.testing.expectEqualStrings(
        "prepared file mutation no longer matches tool call",
        reason,
    );
    try std.testing.expectEqual(@as(usize, 1), file_mutation_decode_count);
    try std.testing.expectEqual(@as(usize, 1), file_mutation_resolution_count);
}

test "file mutation preparation returns semantic failures before permission evaluation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    file_mutation_decode_count = 0;
    file_mutation_resolution_count = 0;
    const malformed = try prepareFileMutationCall(arena, .{
        .id = "malformed",
        .name = "write_file",
        .arguments_json = "{",
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    });
    try std.testing.expectEqual(@as(std.meta.Tag(FileMutationPreparation), .tool_failure), std.meta.activeTag(malformed));
    try std.testing.expectEqual(@as(usize, 1), file_mutation_decode_count);
    try std.testing.expectEqual(@as(usize, 0), file_mutation_resolution_count);

    file_mutation_decode_count = 0;
    file_mutation_resolution_count = 0;
    const missing_edit = try prepareFileMutationCall(arena, .{
        .id = "missing-edit",
        .name = "edit_file",
        .arguments_json = "{\"path\":\"missing.txt\",\"old_string\":\"before\",\"new_string\":\"after\"}",
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    });
    const reason = switch (missing_edit) {
        .tool_failure => |value| value,
        .not_file_mutation => return error.TestExpectedToolFailure,
        .prepared => return error.TestExpectedToolFailure,
    };
    try std.testing.expectEqualStrings(
        "file mutation target resolution failed: file_not_found",
        reason,
    );
    try std.testing.expectEqual(@as(usize, 1), file_mutation_decode_count);
    try std.testing.expectEqual(@as(usize, 1), file_mutation_resolution_count);
}

fn checkFileMutationPreparationAllocationFailures(alloc: Allocator, workspace: []const u8) !void {
    var prepared = switch (try prepareFileMutationCall(alloc, .{
        .id = "allocation-write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"nested/file.txt\",\"content\":\"hello\\n\"}",
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .not_file_mutation => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer prepared.deinit(alloc);
}

test "prepared file mutation cleans every partial allocation failure" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        checkFileMutationPreparationAllocationFailures,
        .{workspace},
    );
}

fn decodeRegistryOwnedWrite(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    if (!std.mem.eql(u8, args_json, "registry-owned")) {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "expected registry-owned write input",
        ) };
    }
    return test_builtin_tools.write_file.decode(
        ctx,
        "{\"path\":\"registered.txt\",\"content\":\"registered\\n\"}",
    );
}

test "file mutation preflight uses the supplied registry input contract" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registered_write = test_builtin_tools.write_file;
    registered_write.decode = decodeRegistryOwnedWrite;
    const tools = [_]tool_dispatch.Tool{registered_write};
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };
    var allow_rules = [_]types.PermissionRule{.{
        .permission = @constCast("edit"),
        .pattern = @constCast("**"),
        .action = .allow,
    }};

    const outcome = try preflightFileMutation(arena, .{
        .id = "registered-write",
        .name = "write_file",
        .arguments_json = "registry-owned",
    }, .{
        .tool_registry = registry,
        .workspace_root = workspace,
        .permission_rules = .{ .rules = &allow_rules },
        .permission_mode = .auto,
        .can_prompt = false,
    });
    const authorization = switch (outcome) {
        .allowed => |value| value,
        else => return error.TestExpectedAllowed,
    };
    try std.testing.expectEqual(
        file_mutation_contract.Kind.write,
        std.meta.activeTag(authorization.input),
    );
    try std.testing.expectEqualStrings(
        "registered.txt",
        authorization.input.write.path,
    );
    try std.testing.expectEqualStrings(
        "registered\n",
        authorization.input.write.content,
    );
}

test "file mutation preflight compatibility wrapper preserves deny and target failure outcomes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("edit"),
        .pattern = @constCast("denied.txt"),
        .action = .deny,
    }};

    const denied = try preflightFileMutation(arena, .{
        .id = "denied-write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"denied.txt\",\"content\":\"blocked\"}",
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
        .permission_rules = .{ .rules = &rules },
        .permission_mode = .auto,
        .can_prompt = false,
    });
    try std.testing.expectEqual(
        @as(std.meta.Tag(FileMutationPreflight), .policy_denied),
        std.meta.activeTag(denied),
    );

    const missing = try preflightFileMutation(arena, .{
        .id = "missing-edit",
        .name = "edit_file",
        .arguments_json = "{\"path\":\"missing.txt\",\"old_string\":\"before\",\"new_string\":\"after\"}",
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
        .permission_rules = .{},
        .permission_mode = .auto,
        .can_prompt = false,
    });
    const reason = switch (missing) {
        .tool_failure => |value| value,
        else => return error.TestExpectedToolFailure,
    };
    try std.testing.expectEqualStrings(
        "file mutation target resolution failed: file_not_found",
        reason,
    );
}

test "file mutation preflight fails closed without registered input ownership" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var unbound_write = test_builtin_tools.write_file;
    unbound_write.take_file_mutation_input_fn = null;
    const tools = [_]tool_dispatch.Tool{unbound_write};
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };
    const outcome = try preflightFileMutation(arena_state.allocator(), .{
        .id = "unbound-write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"blocked.txt\",\"content\":\"blocked\"}",
    }, .{
        .tool_registry = registry,
        .workspace_root = "/tmp/workspace",
        .permission_rules = .{},
        .permission_mode = .auto,
        .can_prompt = false,
    });
    const reason = switch (outcome) {
        .tool_failure => |value| value,
        else => return error.TestExpectedToolFailure,
    };
    try std.testing.expectEqualStrings(
        "file mutation tool registration is missing canonical input ownership",
        reason,
    );
}

test "file mutation kind comes from the registered executor kind, not the tool name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var edit_under_write_name = test_builtin_tools.edit_file;
    edit_under_write_name.name = "write_file";
    const tools = [_]tool_dispatch.Tool{edit_under_write_name};

    const decoded = try decodeFileMutationInput(arena, .{ .tools = tools[0..] }, .{
        .id = "declared-edit",
        .name = "write_file",
        .arguments_json = "{\"path\":\"note.txt\",\"old_string\":\"before\",\"new_string\":\"after\"}",
    });
    switch (decoded) {
        .input => |input| try std.testing.expectEqual(
            file_mutation_contract.Kind.edit,
            std.meta.activeTag(input),
        ),
        .not_file_mutation => return error.TestExpectedDecodedInput,
        .failure => return error.TestExpectedDecodedInput,
    }
}

test "file mutation decode accepts a registered tool under any name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var renamed_write = test_builtin_tools.write_file;
    renamed_write.name = "stage_file";
    const tools = [_]tool_dispatch.Tool{renamed_write};

    const decoded = try decodeFileMutationInput(arena, .{ .tools = tools[0..] }, .{
        .id = "renamed-write",
        .name = "stage_file",
        .arguments_json = "{\"path\":\"note.txt\",\"content\":\"hello\\n\"}",
    });
    switch (decoded) {
        .input => |input| try std.testing.expectEqual(
            file_mutation_contract.Kind.write,
            std.meta.activeTag(input),
        ),
        .not_file_mutation => return error.TestExpectedDecodedInput,
        .failure => return error.TestExpectedDecodedInput,
    }
}

test "file mutation decode steps aside for a host tool reusing a reserved name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const HostRaw = struct {
        json: []u8,
    };
    const Hooks = struct {
        fn deinit(raw: *anyopaque, alloc: Allocator) void {
            const input: *HostRaw = @ptrCast(@alignCast(raw));
            alloc.free(input.json);
            alloc.destroy(input);
        }
        fn decode(
            ctx: tool_dispatch.DispatchContext,
            arguments_json: []const u8,
        ) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
            const input = try ctx.allocator.create(HostRaw);
            errdefer ctx.allocator.destroy(input);
            input.* = .{ .json = try ctx.allocator.dupe(u8, arguments_json) };
            return .{ .input = .{ .ptr = input, .deinit_fn = deinit } };
        }
        fn call(
            _: tool_dispatch.DispatchContext,
            _: tool_dispatch.ToolInput,
        ) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
            return error.InvalidToolArguments;
        }
        fn readsOnly(_: tool_dispatch.ToolInput) bool {
            return false;
        }
        fn irreversible(_: tool_dispatch.ToolInput) bool {
            return false;
        }
    };

    const host_tool = tool_dispatch.Tool{
        .name = "write_file",
        .description = "",
        .model_schema = .{ .name = "write_file", .description = "" },
        .model_visible = false,
        .executor_kind = .host,
        .activity_kind = .command,
        .action_label = "Running",
        .completed_action_label = "Ran",
        .decode = Hooks.decode,
        .call = Hooks.call,
        .reads_only_fn = Hooks.readsOnly,
        .irreversible_fn = Hooks.irreversible,
    };
    const tools = [_]tool_dispatch.Tool{host_tool};
    const decoded = try decodeFileMutationInput(arena, .{ .tools = tools[0..] }, .{
        .id = "host-write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"note.txt\",\"content\":\"hi\"}",
    });
    try std.testing.expect(decoded == .not_file_mutation);

    const prepared = try prepareFileMutationCall(arena, .{
        .id = "host-write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"note.txt\",\"content\":\"hi\"}",
    }, .{ .tool_registry = .{ .tools = tools[0..] }, .workspace_root = "/tmp" });
    try std.testing.expect(prepared == .not_file_mutation);
}

test "file mutation decode rejects a registered tool that is not a mutation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tools = [_]tool_dispatch.Tool{test_builtin_tools.read_file};
    const decoded = try decodeFileMutationInput(arena, .{ .tools = tools[0..] }, .{
        .id = "not-a-mutation",
        .name = "read_file",
        .arguments_json = "{\"path\":\"note.txt\"}",
    });
    const reason = switch (decoded) {
        .failure => |value| value,
        .not_file_mutation => return error.TestExpectedToolFailure,
        .input => return error.TestExpectedToolFailure,
    };
    try std.testing.expectEqualStrings("unsupported file mutation tool", reason);
}

const FakeAutoClassifier = struct {
    calls: usize = 0,
    decision: permission_auto_classifier.Decision = .clear,
    risk: permission_auto_classifier.Risk = .low,
    rationale: []const u8 = "test automatic review",
    invalid: bool = false,
    invalid_reason: ?permission_auto_classifier.InvalidReason = null,
    review_model: []const u8 = "",
    review_root_text: []const u8 = "",
    review_target_call_id: []const u8 = "",
    review_untrusted_message_count: usize = 0,
    proven_current_branch: ?[]const u8 = null,
    action_tag: ?std.meta.Tag(permission_auto_classifier.Action) = null,
    exact_command: ?[]const u8 = null,
    exact_arguments_json: ?[]const u8 = null,
    schema_json: ?[]const u8 = null,
    file_display_path: ?[]const u8 = null,
    file_additions: usize = 0,
    file_deletions: usize = 0,
    file_review_rows: usize = 0,

    fn classify(
        raw_ctx: *anyopaque,
        alloc: Allocator,
        request: permission_auto_classifier.ReviewRequest,
    ) anyerror!permission_auto_classifier.ParseOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        self.calls += 1;
        self.review_model = request.review_turn.model;
        self.review_root_text = request.review_turn.trusted_root_context;
        self.review_target_call_id = request.review_turn.target_call_id;
        self.review_untrusted_message_count = request.review_turn.current_turn_untrusted_messages.len;
        self.proven_current_branch = request.proven_bindings.current_branch;
        self.action_tag = std.meta.activeTag(request.action);
        switch (request.action) {
            .shell_input => |shell_input| self.exact_arguments_json = shell_input.arguments_json,
            .command => |command| self.exact_command = command.command,
            .file_mutation => |file| {
                self.file_display_path = file.display_path;
                self.file_additions = file.additions;
                self.file_deletions = file.deletions;
                var viewport = try file.review.viewport(alloc, 0, 1);
                defer viewport.deinit(alloc);
                self.file_review_rows = viewport.total_rows;
            },
            .tool => |tool| {
                self.exact_arguments_json = tool.arguments_json;
                self.schema_json = tool.schema_json;
            },
        }
        if (self.invalid_reason) |reason| return .{ .invalid = reason };
        if (self.invalid) return .{ .invalid = .provider_failed };
        return .{ .valid = .{
            .risk = self.risk,
            .decision = self.decision,
            .rationale = try alloc.dupe(u8, self.rationale),
        } };
    }
};

const test_admission_registry = tool_dispatch.Registry{ .tools = &.{
    test_builtin_tools.glob_files,
    test_builtin_tools.shell,
    test_builtin_tools.shell,
    test_builtin_tools.write_file,
    test_builtin_tools.edit_file,
} };

fn testInputWithClassifier(
    worker: *WorkerRuntime,
    classifier: permission_auto_classifier.Classifier,
) Input {
    return .{
        .workspace_root = "/tmp/workspace",
        .permission_grants = &.{},
        .permission_rules = .{},
        .tool_registry = test_admission_registry,
        .worker = worker,
        .advertised_dynamic_tool_names = &.{},
        .mcp_runtime = .{},
        .auto_classifier = classifier,
        .permission_review_turn = testReviewTurn(),
    };
}

test "resolved skill calls retain name policy and ordinary execution authority" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var input = testInputWithClassifier(&worker, permission_auto_classifier.Classifier.disabled());
    input.tool_registry = .{ .tools = &.{test_builtin_tools.skill} };
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("skill"),
        .pattern = @constCast("restricted-name"),
        .action = .deny,
    }};
    input.permission_rules = .{ .rules = &rules };
    const skill: @import("../skills/skill_contract.zig").PreparedSkill = .{ .skill = .{
        .name = "restricted-name",
        .description = "",
        .path = "/installed/different-directory-name",
        .source = .global_fx,
    } };
    const calls = [_]ToolCall{
        .{ .id = "named", .name = "Skill", .arguments_json = "{\"skill\":\"restricted-name\"}", .resolved_skill = &skill },
        .{ .id = "with_args", .name = "Skill", .arguments_json = "{\"skill\":\"restricted-name\",\"args\":\"fix\"}", .resolved_skill = &skill },
        .{ .id = "repeated", .name = "Skill", .arguments_json = "{\"skill\":\"restricted-name\"}", .resolved_skill = &skill },
    };
    for (calls) |call| {
        try std.testing.expectEqualStrings("restricted-name", try permissionTargetForCall(input, arena, call));
        for ([_]PermissionMode{ .ask, .auto }) |mode| {
            const outcome = try requestPermissionOutcome(input, arena, call, mode, &.{});
            try std.testing.expectEqual(ToolPermissionDecision.policy_denied, outcome.decision);
            try std.testing.expect(outcome.execution_authority == null);
        }
    }
    rules[0].action = .allow;
    const allowed = try requestPermissionOutcome(input, arena, calls[0], .ask, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, allowed.decision);
    try std.testing.expect(allowed.execution_authority.? == .ordinary);
    var unbound = calls[2];
    unbound.resolved_skill = null;
    const old_key = try permissionStateKeyForCall(input, arena, unbound);
    const bound_key = try permissionStateKeyForCall(input, arena, calls[2]);
    try std.testing.expect(old_key.eql(bound_key));
}

test "exact command approval remains valid across live authority revalidation" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    const input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    const call: ToolCall = .{
        .id = "exact-command-revalidation",
        .name = "Bash",
        .arguments_json = "{\"command\":\"printf approved > marker.txt\"}",
    };
    const grants = try exactApprovalLocalGrants(
        input,
        arena,
        call,
        &.{},
        .ordinary,
    );
    var targets = try permissionTargetsForCall(input, arena, call);
    defer targets.deinit(arena);

    try std.testing.expectEqual(@as(usize, 1), grants.len);
    try std.testing.expectEqualStrings("bash", grants[0].tool_name);
    try std.testing.expect(command_environment.isExplicitPermissionCommandIdentity(
        grants[0].target_path,
    ));
    try std.testing.expectEqualStrings(
        "printf approved > marker.txt",
        command_environment.commandFromPermissionIdentity(grants[0].target_path),
    );
    try std.testing.expect(sessionGrantsAllowAll(grants, "bash", targets.items));
}

const test_review_tool_calls = [_]ToolCall{
    .{ .id = "test-review", .name = "Bash", .arguments_json = "{\"command\":\"printf test\"}" },
};
const test_review_root_messages = [_][]const u8{"test root request"};

fn testReviewTurn() permission_auto_classifier.ReviewTurnContext {
    return .{
        .model = "openai/gpt-5",
        .pending_assistant = .{ .role = .assistant, .tool_calls = &test_review_tool_calls },
        .target_call_id = "test-review",
        .origin = .root,
        .trusted_root_context = test_review_root_messages[0],
    };
}

const RecordingPrompter = struct {
    calls: usize = 0,
    decision: ToolPermissionDecision = .once,
    last_call_id: ?[]const u8 = null,
    last_label_len: usize = 0,
    last_label: ?[]const u8 = null,
    last_command: ?[]const u8 = null,
    last_grant_offer: ?[]const PermissionGrant = null,
    last_choice_count: usize = 0,
    last_explanation: ?[]const u8 = null,
    last_amendment_allowed: bool = false,
    selected_option: ?u8 = null,
    feedback: ?[]const u8 = null,
    plan_review: ?permission_request.PlanReviewChoice = null,

    fn request(
        raw: *anyopaque,
        alloc: Allocator,
        request_view: permission_request.PermissionRequest,
        call: ToolCall,
        _: ?*const diff_mod.FileReview,
        grant_offer: ?[]const PermissionGrant,
    ) anyerror!permission_request.OwnedPermissionResponse {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.last_call_id = call.id;
        self.last_label_len = request_view.label.len;
        self.last_label = request_view.label;
        self.last_command = request_view.command;
        self.last_grant_offer = grant_offer;
        self.last_choice_count = request_view.choice_labels.len;
        self.last_explanation = request_view.explanation;
        self.last_amendment_allowed = request_view.amendment_allowed;
        const typed_feedback = if (self.feedback) |text| try alloc.dupe(u8, text) else null;
        var response = permission_request.OwnedPermissionResponse.init(alloc, self.decision, typed_feedback);
        response.selected_option = self.selected_option;
        response.plan_review = self.plan_review;
        return response;
    }

    fn prompter(self: *@This()) permission_prompter.Prompter {
        return .{ .context = @ptrCast(self), .request_fn = request };
    }
};

test "interactive admission routes prompts through the supplied prompter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.permission_prompter = recording.prompter();

    const call = ToolCall{
        .id = "cmd",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch generated.txt\"}",
    };
    const outcome = try requestPermissionOutcome(input, arena_state.allocator(), call, .ask, &.{});
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
    try std.testing.expectEqualStrings(call.id, recording.last_call_id.?);
    const grant_offer = recording.last_grant_offer orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), grant_offer.len);
    try std.testing.expectEqualStrings("bash", grant_offer[0].tool_name);
    try std.testing.expect(command_environment.isExplicitPermissionCommandIdentity(
        grant_offer[0].target_path,
    ));
    try std.testing.expectEqualStrings(
        "touch generated.txt",
        command_environment.commandFromPermissionIdentity(grant_offer[0].target_path),
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    const authority = outcome.execution_authority.?.run_command;
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.interactive_once,
        authority.shell_allowed.source,
    );

    recording.decision = .deny;
    const denied = try requestPermissionOutcome(input, arena_state.allocator(), call, .ask, &.{});
    try std.testing.expectEqual(@as(usize, 2), recording.calls);
    try std.testing.expectEqual(ToolPermissionDecision.deny, denied.decision);
    try std.testing.expect(denied.execution_authority == null);
}

test "interactive file admission passes its canonical grant offer to the prompter" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.workspace_root = workspace;
    input.permission_prompter = recording.prompter();
    const arguments_json = try arena.print(
        "{{\"path\":\"{s}/note.txt\",\"content\":\"hello\\n\"}}",
        .{workspace},
    );

    const outcome = try requestPermissionOutcome(
        input,
        arena,
        .{
            .id = "write",
            .name = "write_file",
            .arguments_json = arguments_json,
        },
        .ask,
        &.{},
    );

    const authorization = switch (outcome.execution_authority.?) {
        .file_mutation => |value| value,
        else => return error.TestExpectedEqual,
    };
    const expected = authorization.grant_offer.?.grants;
    const observed = recording.last_grant_offer.?;
    try std.testing.expectEqual(expected.len, observed.len);
    for (expected, observed) |expected_grant, observed_grant| {
        try std.testing.expectEqualStrings(
            expected_grant.tool_name,
            observed_grant.tool_name,
        );
        try std.testing.expectEqualStrings(
            expected_grant.target_path,
            observed_grant.target_path,
        );
    }
}

test "ask-only policy bypasses prompt in auto and yolo and uses the ordinary prompt in ask" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    var ask_only_tool = test_builtin_tools.read_file;
    ask_only_tool.name = "test_ask_only";
    ask_only_tool.model_schema.name = ask_only_tool.name;
    ask_only_tool.requires_approval = true;
    ask_only_tool.approval_policy = .ask_only;
    ask_only_tool.label_arg_kind = .none;
    ask_only_tool.label_arg_default = "test input";
    ask_only_tool.permission_target_kind = .none;
    const tools = [_]tool_dispatch.Tool{ask_only_tool};
    input.tool_registry = .{ .tools = tools[0..] };
    input.permission_prompter = recording.prompter();
    const call = ToolCall{
        .id = "ask-only-permission",
        .name = "test_ask_only",
        .arguments_json = "{}",
    };

    const automatic = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, automatic.decision);
    try std.testing.expectEqual(command_admission.ToolExecutionAuthority.ordinary, automatic.execution_authority.?);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), recording.calls);

    const yolo = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .yolo,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, yolo.decision);
    try std.testing.expectEqual(@as(usize, 0), recording.calls);

    const interactive = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .ask,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, interactive.decision);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
    try std.testing.expect(recording.last_label_len > 0);

    recording.decision = .deny;
    const denied = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .ask,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.deny, denied.decision);
    try std.testing.expect(denied.execution_authority == null);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 2), recording.calls);
}

test "a PreToolUse hook ask forces a prompt in auto mode and a deny rule still wins without asking" {
    const ForcedAsk = struct {
        call_id: []const u8,
        fn take(_: *anyopaque, _: Allocator, _: []const u8) ?permission_request.OwnedPermissionResponse {
            return null;
        }
        fn asks(raw: *anyopaque, call_id: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return std.mem.eql(u8, self.call_id, call_id);
        }
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    var recording = RecordingPrompter{};
    var forced = ForcedAsk{ .call_id = "hook-asked" };
    var asking = recording.prompter();
    asking.hook_answers = .{ .context = @ptrCast(&forced), .take_fn = ForcedAsk.take, .asks_fn = ForcedAsk.asks };
    input.permission_prompter = asking;

    const plain = try requestPermissionOutcome(input, arena, .{
        .id = "plain",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch observed.txt\"}",
    }, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, plain.decision);
    try std.testing.expectEqual(@as(usize, 0), recording.calls);

    const hooked_call = ToolCall{
        .id = "hook-asked",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch observed.txt\"}",
    };
    _ = try requestPermissionOutcome(input, arena, hooked_call, .auto, &.{});
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
    try std.testing.expectEqualStrings("hook-asked", recording.last_call_id.?);

    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("*"),
        .action = .deny,
    }};
    input.permission_rules = .{ .rules = &rules };
    const denied = try requestPermissionOutcome(input, arena, hooked_call, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, denied.decision);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
}

test "automatic terminal admission approves typed input and keeps configured denies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    const observe_call = ToolCall{
        .id = "terminal-observe",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch observed.txt\"}",
    };

    const observe = try requestPermissionOutcome(input, arena, observe_call, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, observe.decision);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.auto_mode,
        observe.execution_authority.?.run_command.shell_allowed.source,
    );

    const start = try requestPermissionOutcome(input, arena, .{
        .id = "shell-run",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch generated.txt\"}",
    }, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, start.decision);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);

    const asked = try requestPermissionOutcome(input, arena, observe_call, .ask, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, asked.decision);

    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("*"),
        .action = .deny,
    }};
    input.permission_rules = .{ .rules = &rules };
    const denied = try requestPermissionOutcome(input, arena, observe_call, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, denied.decision);

    rules[0].action = .ask;
    const configured_ask = try requestPermissionOutcome(input, arena, observe_call, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, configured_ask.decision);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    const configured_ask_in_yolo = try requestPermissionOutcome(input, arena, observe_call, .yolo, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, configured_ask_in_yolo.decision);

    try std.testing.expectError(
        error.UnexpectedEndOfInput,
        requestPermissionOutcome(input, arena, .{
            .id = "malformed-terminal-observe",
            .name = "Bash",
            .arguments_json = "{",
        }, .auto, &.{}),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "shell admission reuses terminal rules and command authority" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var classifier = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&classifier),
            FakeAutoClassifier.classify,
        ),
    );
    const observe_call = ToolCall{
        .id = "shell-observe",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch observed.txt\"}",
    };
    const observe = try requestPermissionOutcome(input, arena, observe_call, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, observe.decision);
    try std.testing.expectEqual(@as(usize, 0), classifier.calls);

    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("*"),
        .action = .deny,
    }};
    input.permission_rules = .{ .rules = &rules };
    const denied = try requestPermissionOutcome(input, arena, observe_call, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, denied.decision);
    try std.testing.expectEqual(@as(usize, 0), classifier.calls);

    input.permission_rules = .{};
    const run = try requestPermissionOutcome(input, arena, .{
        .id = "shell-run",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch generated.txt\"}",
    }, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, run.decision);
    try std.testing.expect(run.execution_authority != null);
    try std.testing.expectEqual(@as(usize, 0), classifier.calls);
}

test "existing tool approval policies retain the standard default" {
    for (test_admission_registry.tools) |tool| {
        try std.testing.expectEqual(tool_dispatch.ApprovalPolicy.standard, tool.approval_policy);
    }
}

test "yolo admission approves routine commands and keeps configured denies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var classifier = FakeAutoClassifier{};
    var prompter = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&classifier),
            FakeAutoClassifier.classify,
        ),
    );
    input.permission_prompter = prompter.prompter();

    const allowed = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "yolo-command",
            .name = "Bash",
            .arguments_json = "{\"command\":\"touch generated.txt\"}",
        },
        .yolo,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, allowed.decision);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.yolo,
        allowed.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 0), classifier.calls);
    try std.testing.expectEqual(@as(usize, 0), prompter.calls);

    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("*"),
        .action = .deny,
    }};
    input.permission_rules = .{ .rules = &rules };
    const denied = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "yolo-denied-command",
            .name = "Bash",
            .arguments_json = "{\"command\":\"touch generated.txt\"}",
        },
        .yolo,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, denied.decision);
    try std.testing.expectEqual(@as(usize, 0), prompter.calls);

    try std.testing.expectError(
        error.UnexpectedEndOfInput,
        requestPermissionOutcome(
            input,
            arena_state.allocator(),
            .{
                .id = "malformed-yolo-command",
                .name = "Bash",
                .arguments_json = "{",
            },
            .yolo,
            &.{},
        ),
    );
}

test "a Kimi-named deny rule binds to Bash and file writes and carries its reason" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var input = testInputWithClassifier(&worker, permission_auto_classifier.Classifier.disabled());
    input.workspace_root = workspace;
    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("Bash"), .pattern = @constCast("sudo *"), .action = .deny, .reason = @constCast("no sudo here") },
        .{ .permission = @constCast("Write"), .pattern = @constCast("secrets/*"), .action = .deny, .reason = @constCast("secrets are managed elsewhere") },
    };
    input.permission_rules = .{ .rules = &rules };

    const command_denied = try requestPermissionOutcome(input, arena, .{
        .id = "kimi-deny-command",
        .name = "Bash",
        .arguments_json = "{\"command\":\"sudo make install\"}",
    }, .yolo, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, command_denied.decision);
    try std.testing.expectEqualStrings("no sudo here", command_denied.rule_reason.?);

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/secrets");
    const write_denied = try requestPermissionOutcome(input, arena, .{
        .id = "kimi-deny-write",
        .name = "write_file",
        .arguments_json = try arena.print("{{\"path\":\"{s}/secrets/key.txt\",\"content\":\"x\\n\"}}", .{workspace}),
    }, .yolo, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, write_denied.decision);
    try std.testing.expectEqualStrings("secrets are managed elsewhere", write_denied.rule_reason.?);

    const write_allowed = try requestPermissionOutcome(input, arena, .{
        .id = "kimi-allow-write",
        .name = "write_file",
        .arguments_json = try arena.print("{{\"path\":\"{s}/notes.txt\",\"content\":\"x\\n\"}}", .{workspace}),
    }, .yolo, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, write_allowed.decision);
}

test "yolo file admission approves reversible writes and keeps configured denies" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var classifier = FakeAutoClassifier{};
    var prompter = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&classifier),
            FakeAutoClassifier.classify,
        ),
    );
    input.workspace_root = workspace;
    input.permission_prompter = prompter.prompter();
    const target = try std.Io.Dir.path.join(arena, &.{ workspace, "yolo.txt" });
    const arguments = try arena.print(
        "{{\"path\":\"{s}\",\"content\":\"ok\\n\"}}",
        .{target},
    );

    const outcome = try requestPermissionOutcome(
        input,
        arena,
        .{
            .id = "yolo-write",
            .name = "write_file",
            .arguments_json = arguments,
        },
        .yolo,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    const authority = outcome.execution_authority orelse return error.TestExpectedEqual;
    switch (authority) {
        .file_mutation => |authorization| {
            try std.testing.expectEqualStrings(target, authorization.input.path());
            try std.testing.expect(authorization.policy_targets.items.len >= 2);
            try std.testing.expect(authorization.policy_targets.items[1].expected_identity != null);
        },
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqual(@as(usize, 0), classifier.calls);
    try std.testing.expectEqual(@as(usize, 0), prompter.calls);

    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "workspace/yolo.txt", .{
            .truncate = true,
        });
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "ok\n");
    }
    const noop = try requestPermissionOutcome(
        input,
        arena,
        .{
            .id = "yolo-noop-write",
            .name = "write_file",
            .arguments_json = arguments,
        },
        .yolo,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, noop.decision);
    try std.testing.expect(noop.execution_authority != null);
    try std.testing.expectEqual(@as(usize, 0), classifier.calls);
    try std.testing.expectEqual(@as(usize, 0), prompter.calls);

    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("write_file"),
        .pattern = @constCast("*"),
        .action = .deny,
    }};
    input.permission_rules = .{ .rules = &rules };
    const denied = try requestPermissionOutcome(
        input,
        arena,
        .{
            .id = "yolo-denied-write",
            .name = "write_file",
            .arguments_json = arguments,
        },
        .yolo,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, denied.decision);
    try std.testing.expectEqual(@as(usize, 0), prompter.calls);
}

test "admission registration follows the supplied registry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );

    const call = ToolCall{
        .id = "cmd",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch generated.txt\"}",
    };
    input.tool_registry = .{};
    try std.testing.expect(!try callUsesCommandAuthority(
        input.tool_registry,
        arena_state.allocator(),
        call,
    ));
    const unregistered = try requestPermissionOutcome(input, arena_state.allocator(), call, .ask, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, unregistered.decision);
    try std.testing.expectEqual(command_admission.ToolExecutionAuthority.ordinary, unregistered.execution_authority.?);

    input.tool_registry = tool_dispatch.Registry{ .tools = &.{test_builtin_tools.shell} };
    try std.testing.expect(try callUsesCommandAuthority(
        input.tool_registry,
        arena_state.allocator(),
        call,
    ));
    const registered = try requestPermissionOutcome(input, arena_state.allocator(), call, .ask, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, registered.decision);
    try std.testing.expect(registered.execution_authority == null);
}

test "registered subagent commands do not require generic tool approval" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    var subagent = test_builtin_tools.read_file;
    subagent.name = "Agent";
    subagent.model_schema.name = "Agent";
    subagent.executor_kind = .subagent;
    subagent.activity_kind = .subagent;
    subagent.label_arg_kind = .none;
    subagent.permission_target_kind = .none;
    input.tool_registry = .{ .tools = &.{subagent} };

    const outcome = try requestPermissionOutcome(input, arena_state.allocator(), .{
        .id = "subagent-create",
        .name = "Agent",
        .arguments_json = "{}",
    }, .ask, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    try std.testing.expectEqual(command_admission.ToolExecutionAuthority.ordinary, outcome.execution_authority.?);
}

test "web search permission target follows registered tool metadata" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );

    var provider_search = test_builtin_tools.read_file;
    provider_search.name = "provider_search";
    provider_search.model_schema.name = "provider_search";
    provider_search.executor_kind = .web_search;
    provider_search.permission_target_kind = .none;
    const tools = [_]tool_dispatch.Tool{provider_search};
    input.tool_registry = .{ .tools = tools[0..] };

    const target = try permissionTargetForCall(input, arena_state.allocator(), .{
        .id = "provider-search",
        .name = "provider_search",
        .arguments_json = "{\"query\":\"current news\"}",
    });
    try std.testing.expectEqualStrings("provider_search", target);
}

test "permission target kind follows supplied registry metadata" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );

    var provider_read = test_builtin_tools.read_file;
    provider_read.permission_target_kind = .none;
    const tools = [_]tool_dispatch.Tool{provider_read};
    input.tool_registry = .{ .tools = tools[0..] };

    const target = try permissionTargetForCall(input, arena_state.allocator(), .{
        .id = "provider-read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/main.zig\"}",
    });
    try std.testing.expectEqualStrings("read_file", target);
}

test "live authority resolves a missing read target without changing ordinary admission" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/src");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const expected = try std.Io.Dir.path.join(alloc, &.{ workspace, "src/missing.zig" });
    defer alloc.free(expected);
    const external_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(external_root);
    const external_expected = try std.Io.Dir.path.join(
        alloc,
        &.{ external_root, "external-missing.zig" },
    );
    defer alloc.free(external_expected);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.workspace_root = workspace;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.read_file} };
    const call: ToolCall = .{
        .id = "missing-read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/missing.zig\"}",
    };

    try std.testing.expectError(
        error.FileNotFound,
        permissionTargetForCall(input, arena_state.allocator(), call),
    );
    try std.testing.expectEqualStrings(
        expected,
        try permissionTargetForLiveAuthority(
            input,
            arena_state.allocator(),
            call,
        ),
    );
    try std.testing.expectEqualStrings(
        external_expected,
        try permissionTargetForLiveAuthority(
            input,
            arena_state.allocator(),
            .{
                .id = "external-missing-read",
                .name = "read_file",
                .arguments_json = try arena_state.allocator().print(
                    "{{\"path\":\"{s}\"}}",
                    .{external_expected},
                ),
            },
        ),
    );
}

test "live authority preserves a non-directory read failure for tool execution" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    var blocking_file = try tmp.dir.createFile(io_mod.getIo(), "workspace/not-a-dir", .{});
    blocking_file.close(io_mod.getIo());
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const expected = try std.Io.Dir.path.join(alloc, &.{ workspace, "not-a-dir/child.txt" });
    defer alloc.free(expected);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.workspace_root = workspace;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.read_file} };
    const call: ToolCall = .{
        .id = "not-dir-read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"not-a-dir/child.txt\"}",
    };

    if (permissionTargetForCall(input, arena_state.allocator(), call)) |_| {
        return error.TestExpectedPathResolutionFailure;
    } else |err| {
        try std.testing.expect(err == error.FileNotFound or err == error.NotDir);
    }
    try std.testing.expectEqualStrings(
        expected,
        try permissionTargetForLiveAuthority(
            input,
            arena_state.allocator(),
            call,
        ),
    );
}

test "permission rule display follows supplied registry metadata" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );

    var provider_glob = test_builtin_tools.glob_files;
    provider_glob.name = "provider_glob";
    provider_glob.model_schema.name = "provider_glob";
    const tools = [_]tool_dispatch.Tool{provider_glob};
    input.tool_registry = .{ .tools = tools[0..] };
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("provider_glob"),
        .pattern = @constCast("."),
        .action = .deny,
    }};
    input.permission_rules = .{ .rules = rules[0..] };

    const outcome = try requestPermissionOutcome(input, arena_state.allocator(), .{
        .id = "provider-glob",
        .name = "provider_glob",
        .arguments_json = "{\"pattern\":\"*\"}",
    }, .ask, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, outcome.decision);
}

test "auto approves dangerous commands without asking while yolo asks for them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.permission_prompter = recording.prompter();

    const automatic = try requestPermissionOutcome(input, arena, .{
        .id = "dangerous-auto",
        .name = "Bash",
        .arguments_json = "{\"command\":\"sudo rm -rf public\"}",
    }, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, automatic.decision);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.auto_mode,
        automatic.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 0), recording.calls);

    const asked = try requestPermissionOutcome(input, arena, .{
        .id = "dangerous-yolo",
        .name = "Bash",
        .arguments_json = "{\"command\":\"sudo rm -rf public\"}",
    }, .yolo, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, asked.decision);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);

    const routine = try requestPermissionOutcome(input, arena, .{
        .id = "routine-yolo",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch generated.txt\"}",
    }, .yolo, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, routine.decision);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.yolo,
        routine.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "the dangerous command guard setting gates the yolo dangerous-command ask" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(&worker, permission_auto_classifier.Classifier.disabled());
    input.permission_prompter = recording.prompter();
    const call: ToolCall = .{
        .id = "dangerous-guard-yolo",
        .name = "Bash",
        .arguments_json = "{\"command\":\"sudo rm -rf public\"}",
    };

    _ = try requestPermissionOutcome(input, arena, call, .yolo, &.{});
    try std.testing.expectEqual(@as(usize, 1), recording.calls);

    input.sensitive_file_guard = false;
    const unguarded = try requestPermissionOutcome(input, arena, call, .yolo, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, unguarded.decision);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.yolo,
        unguarded.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
}

test "configured allow remains authoritative for a destructive command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("rm -rf public"),
        .action = .allow,
    }};
    input.permission_rules = .{ .rules = &rules };

    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "configured-destructive",
            .name = "Bash",
            .arguments_json = "{\"command\":\"rm -rf public\"}",
        },
        .auto,
        &.{},
    );

    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.configured_rule,
        outcome.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "configured command authority is used before auto authority" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );

    const direct = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "direct",
            .name = "Bash",
            .arguments_json = "{\"command\":\"pwd\"}",
        },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, direct.decision);

    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("touch *"),
        .action = .allow,
    }};
    input.permission_rules = .{ .rules = &rules };
    input.permission_prompter = recording.prompter();
    const configured = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "configured",
            .name = "Bash",
            .arguments_json = "{\"command\":\"touch configured.txt\"}",
        },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.configured_rule,
        configured.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 0), recording.calls);

    const compound = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "compound",
            .name = "Bash",
            .arguments_json = "{\"command\":\"touch configured.txt && printf bypass\"}",
        },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.auto_mode,
        compound.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), recording.calls);
}

test "automatic clean direct command stays direct without a reviewer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{ .decision = .caution };
    const input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );

    const outcome = requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "clean-direct",
            .name = "Bash",
            .arguments_json = "{\"command\":\"pwd\",\"profile\":\"clean\"}",
        },
        .auto,
        &.{},
    ) catch |err| switch (err) {
        error.MissingLoginShell, error.UnsupportedShell => return error.SkipZigTest,
        else => return err,
    };

    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    const authority = outcome.execution_authority orelse return error.TestExpectedEqual;
    switch (authority.run_command) {
        .direct_only => |fingerprint| try std.testing.expectEqual(
            std.meta.Tag(command_environment.Environment).clean,
            std.meta.activeTag(fingerprint.environment),
        ),
        .shell_allowed => return error.TestExpectedDirectOnly,
    }
}

test "automatic clean TTY command runs with auto shell authority" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    const input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );

    const outcome = requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "clean-tty",
            .name = "Bash",
            .arguments_json = "{\"command\":\"pwd\",\"profile\":\"clean\",\"tty\":true}",
        },
        .auto,
        &.{},
    ) catch |err| switch (err) {
        error.MissingLoginShell, error.UnsupportedShell => return error.SkipZigTest,
        else => return err,
    };

    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    const authority = outcome.execution_authority orelse return error.TestExpectedEqual;
    switch (authority.run_command) {
        .shell_allowed => |allowed| try std.testing.expectEqual(
            command_admission.ShellAuthorizationSource.auto_mode,
            allowed.source,
        ),
        .direct_only => return error.TestExpectedShellAllowed,
    }
}

test "TTY admission fingerprints route and explicit shell startup" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    const input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    const arena = arena_state.allocator();

    const captured = runCommandContext(input, arena, .{
        .id = "captured-clean",
        .name = "Bash",
        .arguments_json = "{\"command\":\"pwd\",\"profile\":\"clean\"}",
    }) catch |err| switch (err) {
        error.MissingLoginShell, error.UnsupportedShell => return error.SkipZigTest,
        else => return err,
    };
    const tty = try runCommandContext(input, arena, .{
        .id = "tty-clean",
        .name = "Bash",
        .arguments_json = "{\"command\":\"pwd\",\"profile\":\"clean\",\"tty\":true}",
    });
    try std.testing.expect(!command_admission.AdmissionFingerprint.init(captured).eql(
        command_admission.AdmissionFingerprint.init(tty),
    ));
    const captured_key = try permissionStateKeyForCall(input, arena, .{
        .id = "captured-key",
        .name = "Bash",
        .arguments_json = "{\"command\":\"pwd\",\"profile\":\"clean\"}",
    });
    const tty_key = try permissionStateKeyForCall(input, arena, .{
        .id = "tty-key",
        .name = "Bash",
        .arguments_json = "{\"command\":\"pwd\",\"profile\":\"clean\",\"tty\":true}",
    });
    try std.testing.expect(!session_permission_state.RuleKey.eql(captured_key, tty_key));
    const captured_target = try permissionTargetForCall(input, arena, .{
        .id = "captured-target",
        .name = "Bash",
        .arguments_json = "{\"command\":\"pwd\",\"profile\":\"clean\"}",
    });
    const tty_target = try permissionTargetForCall(input, arena, .{
        .id = "tty-target",
        .name = "Bash",
        .arguments_json = "{\"command\":\"pwd\",\"profile\":\"clean\",\"tty\":true}",
    });
    const captured_grants = try permissions.suggestedSessionGrants(
        arena,
        input.workspace_root,
        "run_command",
        captured_target,
        .command_cwd,
    );
    try std.testing.expect(permissions.sessionGrantAllowed(
        captured_grants,
        "run_command",
        captured_target,
    ));
    try std.testing.expect(!permissions.sessionGrantAllowed(
        captured_grants,
        "run_command",
        tty_target,
    ));

    const clean_shell = try runCommandContext(input, arena, .{
        .id = "tty-shell-clean",
        .name = "Bash",
        .arguments_json = "{\"command\":\"pwd\",\"tty\":true,\"shell\":{\"kind\":\"executable\",\"path\":\"/bin/bash\",\"clean_start\":true}}",
    });
    const user_shell = try runCommandContext(input, arena, .{
        .id = "tty-shell-user",
        .name = "Bash",
        .arguments_json = "{\"command\":\"pwd\",\"tty\":true,\"shell\":{\"kind\":\"executable\",\"path\":\"/bin/bash\",\"clean_start\":false}}",
    });
    try std.testing.expect(!command_admission.AdmissionFingerprint.init(clean_shell).eql(
        command_admission.AdmissionFingerprint.init(user_shell),
    ));
    const encoded_clean_shell = try runCommandContext(input, arena, .{
        .id = "tty-shell-encoded",
        .name = "Bash",
        .arguments_json = "{\"command\":\"pwd\",\"tty\":true,\"shell\":\"{\\\"kind\\\":\\\"executable\\\",\\\"path\\\":\\\"/bin/bash\\\",\\\"clean_start\\\":true}\"}",
    });
    try std.testing.expect(command_admission.AdmissionFingerprint.init(clean_shell).eql(
        command_admission.AdmissionFingerprint.init(encoded_clean_shell),
    ));
    const clean_shell_key = try permissionStateKeyForCall(input, arena, .{
        .id = "tty-shell-clean-key",
        .name = "Bash",
        .arguments_json = "{\"command\":\"pwd\",\"tty\":true,\"shell\":{\"kind\":\"executable\",\"path\":\"/bin/bash\",\"clean_start\":true}}",
    });
    const user_shell_key = try permissionStateKeyForCall(input, arena, .{
        .id = "tty-shell-user-key",
        .name = "Bash",
        .arguments_json = "{\"command\":\"pwd\",\"tty\":true,\"shell\":{\"kind\":\"executable\",\"path\":\"/bin/bash\",\"clean_start\":false}}",
    });
    try std.testing.expect(!session_permission_state.RuleKey.eql(
        clean_shell_key,
        user_shell_key,
    ));
}

fn npmAliasSnapshotCapture(request: shell_snapshot.CaptureRequest) shell_snapshot.CaptureOutcome {
    const generation = shell_snapshot.Generation.create() catch return .{ .failed = .out_of_memory };
    const alloc = generation.arena.allocator();
    generation.shell_path = alloc.dupe(u8, request.shell_path) catch {
        generation.destroy();
        return .{ .failed = .out_of_memory };
    };
    generation.names.put(alloc, "npm", {}) catch {
        generation.destroy();
        return .{ .failed = .out_of_memory };
    };
    return .{ .ready = generation };
}

test "routine commands that a user alias or function redefines run with auto authority" {
    shell_snapshot.resetProcessOwnerForTest(npmAliasSnapshotCapture);
    defer shell_snapshot.resetProcessOwnerForTest(shell_snapshot.real_capture_fn);
    const lease = (try shell_snapshot.processOwner().acquire("/bin/zsh", "/tmp", .{})).snapshot;
    lease.release();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    const input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    const redefined = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{ .id = "aliased", .name = "Bash", .arguments_json = "{\"command\":\"npm install 2>&1\"}" },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.auto_mode,
        redefined.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);

    const routine = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{ .id = "routine", .name = "Bash", .arguments_json = "{\"command\":\"git status --short\"}" },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.auto_mode,
        routine.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

fn failedSnapshotCapture(_: shell_snapshot.CaptureRequest) shell_snapshot.CaptureOutcome {
    return .{ .failed = .too_large };
}

test "routine commands run with auto authority while the snapshot has fallen back" {
    shell_snapshot.resetProcessOwnerForTest(failedSnapshotCapture);
    defer shell_snapshot.resetProcessOwnerForTest(shell_snapshot.real_capture_fn);
    try std.testing.expect((try shell_snapshot.processOwner().acquire("/bin/zsh", "/tmp", .{})) == .full_startup);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    const input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{ .id = "fallback", .name = "Bash", .arguments_json = "{\"command\":\"git status --short\"}" },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.auto_mode,
        outcome.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "auto commands run with auto authority without a reviewer" {
    shell_snapshot.resetProcessOwnerForTest(shell_snapshot.real_capture_fn);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    const input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    for ([_][]const u8{
        "node -v && npm -v",
        "git status --short --branch",
        "git fetch origin main",
        "npm install 2>&1",
        "npm run dev",
        "zig build test",
    }) |command| {
        const arguments = try arena_state.allocator().print(
            "{{\"command\":{f}}}",
            .{std.json.fmt(command, .{})},
        );
        const outcome = try requestPermissionOutcome(
            input,
            arena_state.allocator(),
            .{ .id = "ordinary", .name = "Bash", .arguments_json = arguments },
            .auto,
            &.{},
        );
        try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
        try std.testing.expectEqual(
            command_admission.ShellAuthorizationSource.auto_mode,
            outcome.execution_authority.?.run_command.shell_allowed.source,
        );
    }
    try std.testing.expectEqual(@as(usize, 0), fake.calls);

    const tty = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "known-reversible-tty",
            .name = "Bash",
            .arguments_json = "{\"command\":\"git status --short --branch\",\"profile\":\"clean\",\"tty\":true}",
        },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.auto_mode,
        tty.execution_authority.?.run_command.shell_allowed.source,
    );
}

test "automatic git that safe git refuses is held instead of running plain git" {
    shell_snapshot.resetProcessOwnerForTest(shell_snapshot.real_capture_fn);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "workspace/.git/objects");
    try tmp.dir.createDirPath(std.testing.io, "workspace/.git/refs");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "workspace/.git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fsmonitor.inc", .data = "[core]\n\tfsmonitor = /bin/sh\n" });
    const include_target = try io_mod.dirRealpathAlloc(arena, tmp.dir, "fsmonitor.inc");
    try tmp.dir.symLink(std.testing.io, include_target, "workspace/.git/fsmonitor.inc", .{ .is_directory = false });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "workspace/.git/config", .data = "[include]\n\tpath = fsmonitor.inc\n" });

    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.workspace_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, "workspace");

    for ([_][]const u8{ "git status", "git status --short --branch", "git diff" }) |command| {
        const arguments = try arena.print(
            "{{\"command\":{f},\"profile\":\"clean\"}}",
            .{std.json.fmt(command, .{})},
        );
        const call: ToolCall = .{ .id = "refused-git", .name = "Bash", .arguments_json = arguments };
        const held = try requestPermissionOutcome(input, arena, call, .auto, &.{});
        try std.testing.expect(held.execution_authority == null);
        try std.testing.expectEqualStrings(unsafe_git_hold_output, held.tool_failure.?);

        const asked = try requestPermissionOutcome(input, arena, call, .ask, &.{});
        try std.testing.expect(asked.tool_failure == null);
        try std.testing.expectEqual(ToolPermissionDecision.permission_required, asked.decision);
    }
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "session deny narrows configured command allow" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    var recording = RecordingPrompter{};
    input.permission_prompter = recording.prompter();
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("touch *"),
        .action = .allow,
    }};
    input.permission_rules = .{ .rules = &rules };
    const call = ToolCall{
        .id = "configured-session-deny",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch configured.txt\"}",
    };
    const key = try permissionStateKeyForCall(input, arena, call);
    try std.testing.expect(std.mem.find(u8, key.canonical, "fx-permission-state-v2") != null);
    try std.testing.expect(std.mem.find(u8, key.canonical, "restricted") == null);
    try std.testing.expect(std.mem.find(u8, key.canonical, "none") == null);
    var empty: session_permission_state.State = .{};
    defer empty.deinit(alloc);
    var applied = try session_permission_state.apply(alloc, empty, .{ .set = .{
        .key = key,
        .display_identity = "touch configured.txt",
        .decision = .deny,
        .expected_generation = null,
    } });
    var state = applied.takeApplied() orelse return error.TestExpectedAppliedState;
    defer state.deinit(alloc);
    input.session_permission_state = &state;

    const denied = try requestPermissionOutcome(
        input,
        arena,
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, denied.decision);
    try std.testing.expect(denied.execution_authority == null);
    try std.testing.expectEqual(@as(usize, 0), recording.calls);
}

test "prepared session deny blocks local file mutation without setup effects" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.workspace_root = workspace;
    const call = ToolCall{
        .id = "prepared-file-session-deny",
        .name = "write_file",
        .arguments_json = "{\"path\":\"blocked.txt\",\"content\":\"blocked\"}",
    };
    const identity = try preparePermissionStateAction(input, arena, call);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.openFile(io_mod.getIo(), "workspace/blocked.txt", .{}),
    );
    var empty: session_permission_state.State = .{};
    defer empty.deinit(alloc);
    var applied = try session_permission_state.apply(alloc, empty, .{ .set = .{
        .key = identity.key,
        .display_identity = identity.display_identity,
        .decision = .deny,
        .expected_generation = null,
    } });
    var state = applied.takeApplied() orelse return error.TestExpectedAppliedState;
    defer state.deinit(alloc);
    input.session_permission_state = &state;

    const denied = try requestPermissionOutcome(input, arena, call, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, denied.decision);
    try std.testing.expect(denied.execution_authority == null);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.openFile(io_mod.getIo(), "workspace/blocked.txt", .{}),
    );
}

test "js host workspace sandbox default is lowest priority and prompt disables it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.host_sandbox_default = .allow_sandboxed;
    const call = ToolCall{
        .id = "browser-command",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch created.txt\"}",
    };

    const allowed = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, allowed.decision);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.js_host,
        allowed.execution_authority.?.run_command.shell_allowed.source,
    );

    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("touch *"),
        .action = .deny,
    }};
    input.permission_rules = .{ .rules = &rules };
    const denied = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, denied.decision);
    try std.testing.expect(denied.execution_authority == null);

    rules[0].action = .ask;
    const asked = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, asked.decision);
    try std.testing.expect(asked.execution_authority == null);

    rules[0].action = .allow;
    const explicitly_allowed = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, explicitly_allowed.decision);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.configured_rule,
        explicitly_allowed.execution_authority.?.run_command.shell_allowed.source,
    );

    input.permission_rules = .{};
    input.host_sandbox_default = .prompt;
    const prompted = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, prompted.decision);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.auto_mode,
        prompted.execution_authority.?.run_command.shell_allowed.source,
    );
}

test "auto external file write is approved without a reviewer packet" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");

    const workspace = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace",
    );
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "external",
    );
    defer alloc.free(external);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.workspace_root = workspace;
    const target_path = try std.Io.Dir.path.join(
        arena,
        &.{ external, "desktop-test.txt" },
    );
    {
        var existing = try tmp.dir.createFile(
            io_mod.getIo(),
            "external/desktop-test.txt",
            .{ .truncate = true },
        );
        defer existing.close(io_mod.getIo());
        try existing.writeStreamingAll(io_mod.getIo(), "before\n");
    }
    const arguments_json = try arena.print(
        "{{\"path\":\"{s}\",\"content\":\"hello\\n\"}}",
        .{target_path},
    );
    const outcome = try requestPermissionOutcome(
        input,
        arena,
        .{
            .id = "write",
            .name = "write_file",
            .arguments_json = arguments_json,
        },
        .auto,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    const authority = outcome.execution_authority orelse
        return error.TestExpectedEqual;
    const authorization = switch (authority) {
        .file_mutation => |value| value,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expectEqualStrings(
        target_path,
        authorization.input.path(),
    );
}

test "automatic workspace write uses reversible admission without reviewer" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    var editable = try tmp.dir.createFile(
        io_mod.getIo(),
        "workspace/editable.txt",
        .{ .truncate = true },
    );
    defer editable.close(io_mod.getIo());
    try editable.writeStreamingAll(io_mod.getIo(), "before\n");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.workspace_root = workspace;
    const target_path = try std.Io.Dir.path.join(arena, &.{ workspace, "note.txt" });
    const arguments_json = try arena.print(
        "{{\"path\":\"{s}\",\"content\":\"hello\\n\"}}",
        .{target_path},
    );

    const outcome = try requestPermissionOutcome(
        input,
        arena,
        .{
            .id = "workspace-write",
            .name = "write_file",
            .arguments_json = arguments_json,
        },
        .auto,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    const authority = outcome.execution_authority orelse
        return error.TestExpectedEqual;
    const authorization = switch (authority) {
        .file_mutation => |value| value,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expectEqualStrings(target_path, authorization.input.path());

    const edit_target = try std.Io.Dir.path.join(arena, &.{ workspace, "editable.txt" });
    const edit_arguments = try arena.print(
        "{{\"path\":\"{s}\",\"old_string\":\"before\",\"new_string\":\"after\"}}",
        .{edit_target},
    );
    const edit_outcome = try requestPermissionOutcome(
        input,
        arena,
        .{
            .id = "workspace-edit",
            .name = "edit_file",
            .arguments_json = edit_arguments,
        },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(ToolPermissionDecision.once, edit_outcome.decision);
    try std.testing.expect(edit_outcome.execution_authority.? == .file_mutation);
}

test "auto writes to added and external roots are approved without a reviewer" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "added");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const added = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "added");
    defer alloc.free(added);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.workspace_root = workspace;
    var additional = [_]workspace_access.Entry{.{
        .path = @constCast(added),
        .saved = false,
        .command_line = true,
        .available = true,
        .active = true,
    }};
    input.access_scope = .{
        .primary_directory = workspace,
        .additional_directories = &additional,
    };

    const cases = [_]struct {
        id: []const u8,
        root: []const u8,
    }{
        .{ .id = "added-write", .root = added },
        .{ .id = "external-write", .root = external },
    };
    for (cases) |case| {
        const target_path = try std.Io.Dir.path.join(arena, &.{ case.root, "note.txt" });
        const arguments_json = try arena.print(
            "{{\"path\":\"{s}\",\"content\":\"hello\\n\"}}",
            .{target_path},
        );
        const outcome = try requestPermissionOutcome(
            input,
            arena,
            .{
                .id = case.id,
                .name = "write_file",
                .arguments_json = arguments_json,
            },
            .auto,
            &.{},
        );
        try std.testing.expectEqual(@as(usize, 0), fake.calls);
        try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
        const authority = outcome.execution_authority orelse
            return error.TestExpectedEqual;
        try std.testing.expect(authority == .file_mutation);
    }
}

test "auto approves ordinary commands without review authority or budget" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );

    input.permission_review_turn = null;
    const without_authority = try requestPermissionOutcome(
        input,
        arena,
        .{ .id = "no-review-authority", .name = "Bash", .arguments_json = "{\"command\":\"touch public\"}" },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, without_authority.decision);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.auto_mode,
        without_authority.execution_authority.?.run_command.shell_allowed.source,
    );

    input.permission_review_turn = testReviewTurn();
    input.permission_review_turn.?.review_attempt_available = false;
    const exhausted = try requestPermissionOutcome(
        input,
        arena,
        .{ .id = "exhausted-budget", .name = "Bash", .arguments_json = "{\"command\":\"touch unresolved.txt\"}" },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, exhausted.decision);
    try std.testing.expect(exhausted.denial_reason == null);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.auto_mode,
        exhausted.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "auto approves a command a reviewer would hold and ignores classifier output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);

    var caution = FakeAutoClassifier{
        .decision = .caution,
        .risk = .high,
        .rationale = "The command exceeds the user's request.",
    };
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&caution),
            FakeAutoClassifier.classify,
        ),
    );
    const held = try requestPermissionOutcome(
        input,
        arena,
        .{ .id = "held-by-caution", .name = "Bash", .arguments_json = "{\"command\":\"touch public\"}" },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, held.decision);
    try std.testing.expect(held.denial_reason == null);
    try std.testing.expect(held.execution_authority != null);
    try std.testing.expectEqual(@as(usize, 0), caution.calls);

    var invalid = FakeAutoClassifier{ .invalid = true };
    input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&invalid),
            FakeAutoClassifier.classify,
        ),
    );
    const unparsed = try requestPermissionOutcome(
        input,
        arena,
        .{ .id = "invalid-review", .name = "Bash", .arguments_json = "{\"command\":\"touch invalid.txt\"}" },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, unparsed.decision);
    try std.testing.expect(unparsed.denial_reason == null);
    try std.testing.expect(unparsed.execution_authority != null);
    try std.testing.expectEqual(@as(usize, 0), invalid.calls);
}

test "auto terminal start is approved and never sent to a reviewer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    const input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    const outcome = try requestPermissionOutcome(
        input,
        arena,
        .{
            .id = "terminal-start",
            .name = "Bash",
            .arguments_json = "{\"action\":\"start\",\"command\":\"printf ready\",\"backend\":\"native\"}",
        },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expect(fake.exact_arguments_json == null);
    try std.testing.expect(fake.schema_json == null);
}

test "auto approves an advertised dynamic MCP call without a review payload" {
    const Mcp = struct {
        fn hasTool(_: *anyopaque, name: []const u8, _: tool_mcp_runtime.Access) bool {
            return std.mem.eql(u8, name, "mcp_example_write");
        }
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var marker: u8 = 0;
    var fake = FakeAutoClassifier{};
    const advertised = [_][]const u8{"mcp_example_write"};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.advertised_dynamic_tool_names = &advertised;
    input.mcp_review_schema_json = "{\"name\":\"mcp_example_write\",\"inputSchema\":{\"type\":\"object\"}}";
    input.mcp_runtime = .{
        .context = @ptrCast(&marker),
        .has_tool = Mcp.hasTool,
    };
    const outcome = try requestPermissionOutcome(
        input,
        arena,
        .{
            .id = "mcp-call",
            .name = "mcp_example_write",
            .arguments_json = "{\"path\":\"outside.txt\",\"value\":\"exact\"}",
        },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    try std.testing.expect(outcome.execution_authority != null);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expect(fake.exact_arguments_json == null);
    try std.testing.expect(fake.schema_json == null);
}

test "auto approves delegated and compound shell commands without a classifier call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{ .decision = .caution };
    const input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    for ([_][]const u8{
        "rtk rm -rf generated",
        "printf ok # harmless; rm victim",
        "cat <<EOF\nrm victim\nEOF",
        "rm --help",
        "rm",
        "rm -f; printf ok",
        "rm -f < input.txt",
    }) |command| {
        const arguments_json = try arena.print(
            "{{\"command\":{f}}}",
            .{std.json.fmt(command, .{})},
        );
        const outcome = try requestPermissionOutcome(
            input,
            arena,
            .{ .id = command, .name = "Bash", .arguments_json = arguments_json },
            .auto,
            &.{},
        );
        try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
        try std.testing.expect(outcome.denial_reason == null);
    }
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "auto persistence-target writes are approved without a reviewer" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.git/hooks");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.ssh");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/Library/LaunchAgents");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.workspace_root = workspace;
    const relative_targets = [_][]const u8{
        ".git/hooks/pre-commit",
        ".git/config",
        ".ssh/authorized_keys",
        "Library/LaunchAgents/com.fx.smoke.plist",
    };
    for (relative_targets) |relative_target| {
        const target_path = try std.Io.Dir.path.join(arena, &.{ workspace, relative_target });
        const arguments_json = try arena.print(
            "{{\"path\":\"{s}\",\"content\":\"test\\n\"}}",
            .{target_path},
        );
        const outcome = try requestPermissionOutcome(
            input,
            arena,
            .{ .id = relative_target, .name = "write_file", .arguments_json = arguments_json },
            .auto,
            &.{},
        );
        try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
        const authority = outcome.execution_authority orelse return error.TestExpectedEqual;
        try std.testing.expect(authority == .file_mutation);
    }
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "auto overwrite of a read-denied file is approved without a reviewer" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    var original = try tmp.dir.createFile(
        io_mod.getIo(),
        "workspace/secret.txt",
        .{ .truncate = true },
    );
    defer original.close(io_mod.getIo());
    try original.writeStreamingAll(io_mod.getIo(), "before\n");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.workspace_root = workspace;
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("read_file"),
        .pattern = @constCast("*"),
        .action = .deny,
    }};
    input.permission_rules = .{ .rules = &rules };
    const target_path = try std.Io.Dir.path.join(arena, &.{ workspace, "secret.txt" });
    const arguments_json = try arena.print(
        "{{\"path\":\"{s}\",\"content\":\"after\\n\"}}",
        .{target_path},
    );
    const outcome = try requestPermissionOutcome(
        input,
        arena,
        .{ .id = "read-disclosure-write", .name = "write_file", .arguments_json = arguments_json },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    try std.testing.expect(outcome.denial_reason == null);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "auto git push runs with auto authority without a branch proof" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    const input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    const outcome = try requestPermissionOutcome(
        input,
        arena,
        .{
            .id = "git-push",
            .name = "Bash",
            .arguments_json = "{\"command\":\"git push origin feature/media-ui\"}",
        },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.auto_mode,
        outcome.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "Kimi dangerous commands prompt in ask and yolo and run without a prompt in auto" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(&worker, permission_auto_classifier.Classifier.disabled());
    input.permission_prompter = recording.prompter();
    for ([_][]const u8{
        "sudo rm -rf public",
        "env FOO=1 sh -c 'shutdown -h now'",
        "dd if=/dev/zero of=/dev/sda bs=1M",
        "systemctl poweroff",
        "mkfs.ext4 /dev/sdb1",
    }) |command| {
        const arguments_json = try arena.print(
            "{{\"command\":{f}}}",
            .{std.json.fmt(command, .{})},
        );
        const call = ToolCall{ .id = command, .name = "Bash", .arguments_json = arguments_json };
        const before = recording.calls;

        _ = try requestPermissionOutcome(input, arena, call, .auto, &.{});
        try std.testing.expectEqual(before, recording.calls);

        _ = try requestPermissionOutcome(input, arena, call, .yolo, &.{});
        try std.testing.expectEqual(before + 1, recording.calls);

        _ = try requestPermissionOutcome(input, arena, call, .ask, &.{});
        try std.testing.expectEqual(before + 2, recording.calls);
    }
}
test "sensitive file reads ask in ask and yolo and pass in auto, with the guard off, or under an allow rule" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "workspace/.env", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "KEY=value\n");
    }
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var prompter = RecordingPrompter{};
    var input = testInputWithClassifier(&worker, permission_auto_classifier.Classifier.disabled());
    input.workspace_root = workspace;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.read_file} };
    input.permission_prompter = prompter.prompter();
    const call: ToolCall = .{
        .id = "sensitive-read",
        .name = "read_file",
        .arguments_json = "{\"path\":\".env\"}",
    };

    _ = try requestPermissionOutcome(input, arena, call, .ask, &.{});
    try std.testing.expectEqual(@as(usize, 1), prompter.calls);

    _ = try requestPermissionOutcome(input, arena, call, .yolo, &.{});
    try std.testing.expectEqual(@as(usize, 2), prompter.calls);

    const automatic = try requestPermissionOutcome(input, arena, call, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, automatic.decision);
    try std.testing.expectEqual(@as(usize, 2), prompter.calls);

    input.sensitive_file_guard = false;
    const unguarded = try requestPermissionOutcome(input, arena, call, .yolo, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, unguarded.decision);
    try std.testing.expectEqual(@as(usize, 2), prompter.calls);

    input.sensitive_file_guard = true;
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("read_file"),
        .pattern = @constCast("*"),
        .action = .allow,
    }};
    input.permission_rules = .{ .rules = &rules };
    const allowed = try requestPermissionOutcome(input, arena, call, .yolo, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, allowed.decision);
    try std.testing.expectEqual(@as(usize, 2), prompter.calls);
}

test "dontAsk denies a call that would prompt and still runs an allow-rule call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(&worker, permission_auto_classifier.Classifier.disabled());
    input.permission_prompter = recording.prompter();
    const call = ToolCall{
        .id = "dont-ask-sudo",
        .name = "Bash",
        .arguments_json = "{\"command\":\"sudo rm -rf public\"}",
    };

    _ = try requestPermissionOutcome(input, arena, call, .ask, &.{});
    try std.testing.expectEqual(@as(usize, 1), recording.calls);

    const denied = try requestPermissionOutcome(input, arena, call, .dontAsk, &.{});
    try std.testing.expect(denied.decision.isDenied());
    try std.testing.expectEqual(types.ToolPermissionDenialReason.dont_ask_denied, denied.denial_reason.?);
    try std.testing.expect(denied.execution_authority == null);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);

    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("sudo rm -rf public"),
        .action = .allow,
    }};
    input.permission_rules = .{ .rules = &rules };
    const allowed = try requestPermissionOutcome(input, arena, call, .dontAsk, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, allowed.decision);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
}

test "ask mode prompts for a dangerous shell command whether or not the guard is on" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(&worker, permission_auto_classifier.Classifier.disabled());
    input.permission_prompter = recording.prompter();
    const call = ToolCall{
        .id = "ask-dangerous",
        .name = "Bash",
        .arguments_json = "{\"command\":\"sudo rm -rf public\"}",
    };

    const asked = try requestPermissionOutcome(input, arena, call, .ask, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, asked.decision);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);

    input.sensitive_file_guard = false;
    _ = try requestPermissionOutcome(input, arena, call, .ask, &.{});
    try std.testing.expectEqual(@as(usize, 2), recording.calls);
}

test "dontAsk denies a recursive root removal without prompting" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(&worker, permission_auto_classifier.Classifier.disabled());
    input.permission_prompter = recording.prompter();
    const call = ToolCall{
        .id = "dont-ask-root-rm",
        .name = "Bash",
        .arguments_json = "{\"command\":\"rm -rf /\"}",
    };

    const denied = try requestPermissionOutcome(input, arena, call, .dontAsk, &.{});
    try std.testing.expect(denied.decision.isDenied());
    try std.testing.expect(denied.execution_authority == null);
    try std.testing.expectEqual(@as(usize, 0), recording.calls);
}

test "dontAsk denies a critical removal even when an allow rule permits it" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(&worker, permission_auto_classifier.Classifier.disabled());
    input.permission_prompter = recording.prompter();
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("rm -rf /"),
        .action = .allow,
    }};
    input.permission_rules = .{ .rules = &rules };
    for ([_][]const u8{ "rm -rf /", "rm -rf ~", "rm -rf $HOME", "rm -rf /*" }) |command| {
        rules[0].pattern = @constCast(command);
        const arguments_json = try arena.print("{{\"command\":{f}}}", .{std.json.fmt(command, .{})});
        const call = ToolCall{ .id = command, .name = "Bash", .arguments_json = arguments_json };
        const denied = try requestPermissionOutcome(input, arena, call, .dontAsk, &.{});
        try std.testing.expect(denied.decision.isDenied());
        try std.testing.expectEqual(types.ToolPermissionDenialReason.dont_ask_denied, denied.denial_reason.?);
        try std.testing.expect(denied.execution_authority == null);
    }
    try std.testing.expectEqual(@as(usize, 0), recording.calls);

    rules[0].pattern = @constCast("rm -rf public");
    const allowed = try requestPermissionOutcome(input, arena, .{
        .id = "dont-ask-public",
        .name = "Bash",
        .arguments_json = "{\"command\":\"rm -rf public\"}",
    }, .dontAsk, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, allowed.decision);
    try std.testing.expectEqual(@as(usize, 0), recording.calls);
}

test "yolo asks before a Bash write into a git control path and auto runs it" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(&worker, permission_auto_classifier.Classifier.disabled());
    input.permission_prompter = recording.prompter();
    const write = ToolCall{ .id = "git-write", .name = "Bash", .arguments_json = "{\"command\":\"echo x > .git/config\"}" };
    const routine = ToolCall{ .id = "git-routine", .name = "Bash", .arguments_json = "{\"command\":\"echo x > notes.txt\"}" };

    const auto_write = try requestPermissionOutcome(input, arena, write, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, auto_write.decision);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.auto_mode,
        auto_write.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 0), recording.calls);
    _ = try requestPermissionOutcome(input, arena, write, .yolo, &.{});
    try std.testing.expectEqual(@as(usize, 1), recording.calls);

    const auto_routine = try requestPermissionOutcome(input, arena, routine, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, auto_routine.decision);
    const yolo_routine = try requestPermissionOutcome(input, arena, routine, .yolo, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, yolo_routine.decision);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);

    const denied = try requestPermissionOutcome(input, arena, write, .dontAsk, &.{});
    try std.testing.expect(denied.decision.isDenied());
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
}

test "git control path reads ask in ask and yolo and pass in auto, with the guard off, or under an allow rule" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.git");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "workspace/.git/config", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "[core]\n");
    }
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var prompter = RecordingPrompter{};
    var input = testInputWithClassifier(&worker, permission_auto_classifier.Classifier.disabled());
    input.workspace_root = workspace;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.read_file} };
    input.permission_prompter = prompter.prompter();
    const call: ToolCall = .{
        .id = "git-control-read",
        .name = "read_file",
        .arguments_json = "{\"path\":\".git/config\"}",
    };

    _ = try requestPermissionOutcome(input, arena, call, .ask, &.{});
    try std.testing.expectEqual(@as(usize, 1), prompter.calls);

    _ = try requestPermissionOutcome(input, arena, call, .yolo, &.{});
    try std.testing.expectEqual(@as(usize, 2), prompter.calls);

    const automatic = try requestPermissionOutcome(input, arena, call, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, automatic.decision);
    try std.testing.expectEqual(@as(usize, 2), prompter.calls);

    input.sensitive_file_guard = false;
    const unguarded = try requestPermissionOutcome(input, arena, call, .yolo, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, unguarded.decision);
    try std.testing.expectEqual(@as(usize, 2), prompter.calls);

    input.sensitive_file_guard = true;
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("read_file"),
        .pattern = @constCast("*"),
        .action = .allow,
    }};
    input.permission_rules = .{ .rules = &rules };
    const allowed = try requestPermissionOutcome(input, arena, call, .yolo, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, allowed.decision);
    try std.testing.expectEqual(@as(usize, 2), prompter.calls);
}

test "a dangerous command asks in ask and yolo even under an allow rule or a session grant, and not after the user answered" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(&worker, permission_auto_classifier.Classifier.disabled());
    input.permission_prompter = recording.prompter();
    const dangerous = ToolCall{
        .id = "dangerous-under-allow",
        .name = "Bash",
        .arguments_json = "{\"command\":\"sudo rm -rf public\"}",
    };
    const routine = ToolCall{
        .id = "routine-under-allow",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch generated.txt\"}",
    };
    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("bash"), .pattern = @constCast("sudo rm -rf public"), .action = .allow },
        .{ .permission = @constCast("bash"), .pattern = @constCast("touch generated.txt"), .action = .allow },
    };
    input.permission_rules = .{ .rules = &rules };

    _ = try requestPermissionOutcome(input, arena, dangerous, .ask, &.{});
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
    _ = try requestPermissionOutcome(input, arena, dangerous, .yolo, &.{});
    try std.testing.expectEqual(@as(usize, 2), recording.calls);

    const allowed_routine = try requestPermissionOutcome(input, arena, routine, .ask, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, allowed_routine.decision);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.configured_rule,
        allowed_routine.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 2), recording.calls);

    const automatic = try requestPermissionOutcome(input, arena, dangerous, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, automatic.decision);
    try std.testing.expectEqual(@as(usize, 2), recording.calls);

    input.sensitive_file_guard = false;
    const unguarded = try requestPermissionOutcome(input, arena, dangerous, .yolo, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, unguarded.decision);
    try std.testing.expectEqual(@as(usize, 2), recording.calls);
    input.sensitive_file_guard = true;

    input.permission_rules = .{};
    const grants = try exactApprovalLocalGrants(input, arena, dangerous, &.{}, .ordinary);
    _ = try requestPermissionOutcome(input, arena, dangerous, .yolo, grants);
    try std.testing.expectEqual(@as(usize, 3), recording.calls);

    input.dangerous_command_ask_answered = true;
    const answered = try requestPermissionOutcome(input, arena, dangerous, .yolo, grants);
    try std.testing.expectEqual(ToolPermissionDecision.once, answered.decision);
    try std.testing.expectEqual(@as(usize, 3), recording.calls);

    input.dangerous_command_ask_answered = false;
    input.permission_prompter = null;
    const headless = try requestPermissionOutcome(input, arena, dangerous, .yolo, grants);
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, headless.decision);
}

test "manual mode writes inside a git work tree workspace without a prompt and still asks outside it or for guarded paths" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.git");
    try tmp.dir.createDirPath(io_mod.getIo(), "outside");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const outside = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "outside");
    defer alloc.free(outside);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var prompter = RecordingPrompter{};
    var input = testInputWithClassifier(&worker, permission_auto_classifier.Classifier.disabled());
    input.workspace_root = workspace;
    input.permission_prompter = prompter.prompter();
    const inside_call: ToolCall = .{
        .id = "git-cwd-write",
        .name = "write_file",
        .arguments_json = try arena.print("{{\"path\":\"{s}/note.txt\",\"content\":\"hello\\n\"}}", .{workspace}),
    };

    _ = try requestPermissionOutcome(input, arena, inside_call, .ask, &.{});
    try std.testing.expectEqual(@as(usize, 1), prompter.calls);

    input.workspace_in_git_work_tree = true;
    const approved = try requestPermissionOutcome(input, arena, inside_call, .ask, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, approved.decision);
    try std.testing.expect(approved.execution_authority.? == .file_mutation);
    try std.testing.expectEqual(@as(usize, 1), prompter.calls);

    const dont_ask = try requestPermissionOutcome(input, arena, inside_call, .dontAsk, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, dont_ask.decision);
    try std.testing.expectEqual(@as(usize, 1), prompter.calls);

    const outside_call: ToolCall = .{
        .id = "git-cwd-outside-write",
        .name = "write_file",
        .arguments_json = try arena.print("{{\"path\":\"{s}/note.txt\",\"content\":\"hello\\n\"}}", .{outside}),
    };
    _ = try requestPermissionOutcome(input, arena, outside_call, .ask, &.{});
    try std.testing.expectEqual(@as(usize, 2), prompter.calls);

    const sensitive_call: ToolCall = .{
        .id = "git-cwd-sensitive-write",
        .name = "write_file",
        .arguments_json = try arena.print("{{\"path\":\"{s}/.env\",\"content\":\"KEY=value\\n\"}}", .{workspace}),
    };
    _ = try requestPermissionOutcome(input, arena, sensitive_call, .ask, &.{});
    try std.testing.expectEqual(@as(usize, 3), prompter.calls);

    const control_call: ToolCall = .{
        .id = "git-cwd-control-write",
        .name = "write_file",
        .arguments_json = try arena.print("{{\"path\":\"{s}/.git/hooks/pre-commit\",\"content\":\"exit 1\\n\"}}", .{workspace}),
    };
    _ = try requestPermissionOutcome(input, arena, control_call, .ask, &.{});
    try std.testing.expectEqual(@as(usize, 4), prompter.calls);

    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("edit"),
        .pattern = @constCast("note.txt"),
        .action = .ask,
    }};
    input.permission_rules = .{ .rules = &rules };
    _ = try requestPermissionOutcome(input, arena, inside_call, .ask, &.{});
    try std.testing.expectEqual(@as(usize, 5), prompter.calls);

    input.permission_rules = .{};
    const shell_write: ToolCall = .{
        .id = "git-cwd-shell-write",
        .name = "Bash",
        .arguments_json = "{\"command\":\"touch generated.txt\"}",
    };
    _ = try requestPermissionOutcome(input, arena, shell_write, .ask, &.{});
    try std.testing.expectEqual(@as(usize, 6), prompter.calls);
}

test "dontAsk keeps the sensitive-file guard and denies the read instead of asking" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "workspace/.env", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "KEY=value\n");
    }
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var prompter = RecordingPrompter{};
    var input = testInputWithClassifier(&worker, permission_auto_classifier.Classifier.disabled());
    input.workspace_root = workspace;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.read_file} };
    input.permission_prompter = prompter.prompter();
    const call: ToolCall = .{
        .id = "dont-ask-sensitive-read",
        .name = "read_file",
        .arguments_json = "{\"path\":\".env\"}",
    };

    const denied = try requestPermissionOutcome(input, arena, call, .dontAsk, &.{});
    try std.testing.expect(denied.decision.isDenied());
    try std.testing.expectEqual(types.ToolPermissionDenialReason.dont_ask_denied, denied.denial_reason.?);
    try std.testing.expectEqual(@as(usize, 0), prompter.calls);

    input.sensitive_file_guard = false;
    const unguarded = try requestPermissionOutcome(input, arena, call, .dontAsk, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, unguarded.decision);
    try std.testing.expectEqual(@as(usize, 0), prompter.calls);
}

test "sensitive file reads without a prompter need permission" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "workspace/.env", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "KEY=value\n");
    }
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var input = testInputWithClassifier(&worker, permission_auto_classifier.Classifier.disabled());
    input.workspace_root = workspace;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.read_file} };
    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{ .id = "sensitive-read-headless", .name = "read_file", .arguments_json = "{\"path\":\".env\"}" },
        .yolo,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, outcome.decision);
}

test "yolo asks before writing a sensitive file and writes it without a prompt when the guard is off" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var prompter = RecordingPrompter{};
    var input = testInputWithClassifier(&worker, permission_auto_classifier.Classifier.disabled());
    input.workspace_root = workspace;
    input.permission_prompter = prompter.prompter();
    const target = try std.Io.Dir.path.join(arena, &.{ workspace, ".env" });
    const call: ToolCall = .{
        .id = "sensitive-write",
        .name = "write_file",
        .arguments_json = try arena.print("{{\"path\":\"{s}\",\"content\":\"KEY=value\\n\"}}", .{target}),
    };

    _ = try requestPermissionOutcome(input, arena, call, .yolo, &.{});
    try std.testing.expectEqual(@as(usize, 1), prompter.calls);

    input.sensitive_file_guard = false;
    const unguarded = try requestPermissionOutcome(input, arena, call, .yolo, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, unguarded.decision);
    try std.testing.expectEqual(@as(usize, 1), prompter.calls);
}

test "git control path writes ask in ask and yolo, after the sensitive-file ask, and pass in auto" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.git");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var prompter = RecordingPrompter{};
    var input = testInputWithClassifier(&worker, permission_auto_classifier.Classifier.disabled());
    input.workspace_root = workspace;
    input.permission_prompter = prompter.prompter();
    const target = try std.Io.Dir.path.join(arena, &.{ workspace, ".git", "hooks", "pre-commit" });
    const call: ToolCall = .{
        .id = "git-control-write",
        .name = "write_file",
        .arguments_json = try arena.print("{{\"path\":\"{s}\",\"content\":\"exit 1\\n\"}}", .{target}),
    };

    _ = try requestPermissionOutcome(input, arena, call, .ask, &.{});
    try std.testing.expectEqual(@as(usize, 1), prompter.calls);

    _ = try requestPermissionOutcome(input, arena, call, .yolo, &.{});
    try std.testing.expectEqual(@as(usize, 2), prompter.calls);

    const automatic = try requestPermissionOutcome(input, arena, call, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, automatic.decision);
    try std.testing.expectEqual(@as(usize, 2), prompter.calls);

    input.sensitive_file_guard = false;
    const unguarded = try requestPermissionOutcome(input, arena, call, .yolo, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, unguarded.decision);
    try std.testing.expectEqual(@as(usize, 2), prompter.calls);
}

test "a host tool that writes prompts in ask and runs without a prompt in auto" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    var host_bash = test_builtin_tools.read_file;
    host_bash.name = "bash";
    host_bash.model_schema.name = host_bash.name;
    host_bash.executor_kind = .host;
    host_bash.requires_approval = true;
    host_bash.label_arg_kind = .none;
    host_bash.label_arg_default = "bash";
    host_bash.permission_target_kind = .none;
    const tools = [_]tool_dispatch.Tool{host_bash};
    input.tool_registry = .{ .tools = tools[0..] };
    input.permission_prompter = recording.prompter();
    const call = ToolCall{
        .id = "host-bash-permission",
        .name = "bash",
        .arguments_json = "{\"command\":\"echo approval\"}",
    };

    _ = try requestPermissionOutcome(input, arena_state.allocator(), call, .auto, &.{});
    try std.testing.expectEqual(@as(usize, 0), recording.calls);

    _ = try requestPermissionOutcome(input, arena_state.allocator(), call, .ask, &.{});
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
    try std.testing.expect(recording.last_label_len > 0);
}

test "a host tool with requires_approval in ask mode returns permission_required" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    var probe = test_builtin_tools.read_file;
    probe.name = "host_approval_probe";
    probe.model_schema.name = probe.name;
    probe.executor_kind = .host;
    probe.requires_approval = true;
    probe.label_arg_kind = .none;
    probe.label_arg_default = "probe";
    probe.permission_target_kind = .none;
    var host_bash = probe;
    host_bash.name = "bash";
    host_bash.model_schema.name = host_bash.name;
    const tools = [_]tool_dispatch.Tool{ probe, host_bash };
    input.tool_registry = .{ .tools = tools[0..] };
    input.permission_prompter = null;
    input.host_sandbox_default = .allow_sandboxed;

    const probe_call = ToolCall{ .id = "host-approval-probe", .name = "host_approval_probe", .arguments_json = "{}" };
    const probe_outcome = try requestPermissionOutcome(input, arena_state.allocator(), probe_call, .ask, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, probe_outcome.decision);
    try std.testing.expectEqual(command_admission.PermissionRequirement.approval_required, probe_outcome.requirement.?);

    const bash_call = ToolCall{ .id = "host-approval-bash", .name = "bash", .arguments_json = "{\"command\":\"echo approval\"}" };
    const bash_outcome = try requestPermissionOutcome(input, arena_state.allocator(), bash_call, .ask, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, bash_outcome.decision);
}
