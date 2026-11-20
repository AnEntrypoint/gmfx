const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidKimiSectionShape,
    InvalidKimiSectionValue,
};

pub const max_timeout_ms: i64 = 2147483647;
pub const max_bash_output_chars: usize = 150_000;
pub const print_wait_no_ceiling_s: usize = 2_147_483;

pub const TokenCountingStrategy = enum {
    measured_and_estimated,
    measured,
    estimated,

    pub fn parse(raw: []const u8) ?TokenCountingStrategy {
        if (std.mem.eql(u8, raw, "measured+estimated")) return .measured_and_estimated;
        if (std.mem.eql(u8, raw, "measured")) return .measured;
        if (std.mem.eql(u8, raw, "estimated")) return .estimated;
        return null;
    }
};

pub const PrintBackgroundMode = enum {
    exit,
    drain,
    steer,

    pub fn parse(raw: []const u8) ?PrintBackgroundMode {
        return std.meta.stringToEnum(PrintBackgroundMode, raw);
    }
};

pub const Service = struct {
    base_url: ?[]u8 = null,
    api_key: ?[]u8 = null,

    pub fn deinit(self: *Service, alloc: Allocator) void {
        freeOwned(alloc, self.base_url);
        freeOwned(alloc, self.api_key);
        self.* = .{};
    }

    fn merge(self: *Service, alloc: Allocator, incoming: *Service) void {
        takeOwned(alloc, &self.base_url, &incoming.base_url);
        takeOwned(alloc, &self.api_key, &incoming.api_key);
    }
};

pub const Pair = struct {
    name: []u8,
    value: []u8,
};

pub const Flag = struct {
    name: []u8,
    enabled: bool,
};

pub const ExperimentalDefault = struct {
    name: []const u8,
    enabled: bool,
};

pub const experimental_defaults = [_]ExperimentalDefault{
    .{ .name = "wait_for", .enabled = true },
    .{ .name = "tool_select", .enabled = false },
    .{ .name = "notify_user", .enabled = false },
    .{ .name = "subagent_fork", .enabled = false },
    .{ .name = "tower", .enabled = false },
};

pub const Limits = struct {
    max_context_size: ?usize = null,
    max_input_size: ?usize = null,
    max_output_size: ?usize = null,
    capabilities: ?[][]u8 = null,
    display_name: ?[]u8 = null,
    reasoning_key: ?[]u8 = null,
    adaptive_thinking: ?bool = null,
    support_efforts: ?[][]u8 = null,
    default_effort: ?[]u8 = null,
    off_effort: ?[]u8 = null,

    pub fn deinit(self: *Limits, alloc: Allocator) void {
        freeStringList(alloc, self.capabilities);
        freeOwned(alloc, self.display_name);
        freeOwned(alloc, self.reasoning_key);
        freeStringList(alloc, self.support_efforts);
        freeOwned(alloc, self.default_effort);
        freeOwned(alloc, self.off_effort);
        self.* = .{};
    }
};

pub const ModelAlias = struct {
    alias: []u8,
    provider: ?[]u8 = null,
    model: ?[]u8 = null,
    name: ?[]u8 = null,
    protocol: ?[]u8 = null,
    aliases: ?[][]u8 = null,
    provider_id: ?[]u8 = null,
    base_url: ?[]u8 = null,
    api_key: ?[]u8 = null,
    beta_api: ?bool = null,
    limits: Limits = .{},
    overrides: Limits = .{},

    pub fn deinit(self: *ModelAlias, alloc: Allocator) void {
        alloc.free(self.alias);
        freeOwned(alloc, self.provider);
        freeOwned(alloc, self.model);
        freeOwned(alloc, self.name);
        freeOwned(alloc, self.protocol);
        freeStringList(alloc, self.aliases);
        freeOwned(alloc, self.provider_id);
        freeOwned(alloc, self.base_url);
        freeOwned(alloc, self.api_key);
        self.limits.deinit(alloc);
        self.overrides.deinit(alloc);
        self.* = undefined;
    }
};

pub const ModelOverlay = struct {
    api_key: ?[]u8 = null,
    provider_type: ?[]u8 = null,
    base_url: ?[]u8 = null,
    name: ?[]u8 = null,
    thinking_effort: ?[]u8 = null,
    thinking_keep: ?[]u8 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    max_tokens: ?usize = null,
    max_context_size: ?usize = null,
    max_output_size: ?usize = null,

    pub fn deinit(self: *ModelOverlay, alloc: Allocator) void {
        freeOwned(alloc, self.api_key);
        freeOwned(alloc, self.provider_type);
        freeOwned(alloc, self.base_url);
        freeOwned(alloc, self.name);
        freeOwned(alloc, self.thinking_effort);
        freeOwned(alloc, self.thinking_keep);
        self.* = .{};
    }
};

pub const birdman_default_host = "127.0.0.1";
pub const birdman_default_port: u16 = 19999;
pub const birdman_default_path = "/devtools/browser/birdman";
pub const browser_endpoint_max_bytes = 255;

pub const BrowserRoute = enum {
    birdman,
    cdp,
};

pub const BoundedText = struct {
    buf: [browser_endpoint_max_bytes]u8 = undefined,
    len: usize = 0,

    pub fn fromComptime(comptime text: []const u8) BoundedText {
        var bounded: BoundedText = .{ .len = text.len };
        @memcpy(bounded.buf[0..text.len], text);
        return bounded;
    }

    pub fn set(self: *BoundedText, text: []const u8) Error!void {
        if (text.len == 0 or text.len > self.buf.len) return error.InvalidKimiSectionValue;
        @memcpy(self.buf[0..text.len], text);
        self.len = text.len;
    }

    pub fn slice(self: *const BoundedText) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const BrowserEndpoint = struct {
    route: BrowserRoute = .birdman,
    host: BoundedText = BoundedText.fromComptime(birdman_default_host),
    port: u16 = birdman_default_port,
    path: BoundedText = BoundedText.fromComptime(birdman_default_path),
};

pub const Sections = struct {
    read_default_max_chars: ?usize = null,
    read_max_chars: ?usize = null,
    tools_enabled: ?[][]u8 = null,
    tools_disabled: ?[][]u8 = null,
    default_plan_mode: ?bool = null,
    default_model: ?[]u8 = null,
    dangerous_command_guard: ?bool = null,
    extra_skill_dirs: ?[][]u8 = null,
    merge_all_available_skills: ?bool = null,
    builtin_product_skills: ?bool = null,
    extra_agent_dirs: ?[][]u8 = null,
    identity_name: ?[]u8 = null,
    output_style: ?[]u8 = null,
    identity_slug: ?[]u8 = null,
    services_moonshot_search: Service = .{},
    services_moonshot_fetch: Service = .{},
    experimental: ?[]Flag = null,
    swarm_timeout_ms: ?usize = null,
    subagent_timeout_ms: ?usize = null,
    secondary_model_default_model: ?[]u8 = null,
    secondary_model_default_effort: ?[]u8 = null,
    secondary_model_models: ?[]Pair = null,
    model_aliases: ?[]ModelAlias = null,
    model_catalog_refresh_interval_ms: ?usize = null,
    model_catalog_refresh_on_start: ?bool = null,
    thinking_enabled: ?bool = null,
    thinking_keep: ?[]u8 = null,
    image_max_edge_px: ?usize = null,
    image_read_byte_budget: ?usize = null,
    loop_max_steps_per_turn: ?usize = null,
    loop_max_attempts_per_step: ?usize = null,
    loop_max_ralph_iterations: ?i64 = null,
    loop_reserved_context_size: ?usize = null,
    loop_compaction_trigger_ratio: ?f64 = null,
    loop_compaction_max_attempts: ?usize = null,
    mcp_startup_timeout_ms: ?usize = null,
    mcp_tool_timeout_ms: ?usize = null,
    mcp_default_deferred: ?bool = null,
    mcp_reconnect_initial_delay_ms: ?usize = null,
    mcp_reconnect_max_delay_ms: ?usize = null,
    task_max_running_tasks: ?usize = null,
    task_keep_alive_on_exit: ?bool = null,
    task_bash_auto_background_on_timeout: ?bool = null,
    task_bash_timeout_s: ?usize = null,
    task_kill_grace_period_ms: ?usize = null,
    task_stuck_after_s: ?usize = null,
    task_root_job_wait_s: ?usize = null,
    task_root_min_free_mb: ?usize = null,
    task_bash_output_max_chars: ?usize = null,
    task_background_disabled: ?bool = null,
    task_print_background_mode: ?PrintBackgroundMode = null,
    task_print_max_turns: ?usize = null,
    task_print_wait_ceiling_s: ?usize = null,
    database_base: ?bool = null,
    database_global_search: ?bool = null,
    database_search: ?bool = null,
    database_search_sync_session_cap: ?usize = null,
    database_search_sync_debounce_ms: ?usize = null,
    token_counting_strategy: ?TokenCountingStrategy = null,
    workspace_require_trust: ?bool = null,
    watch_enabled: ?bool = null,
    cron_debug: ?bool = null,
    cron_no_jitter: ?bool = null,
    cron_no_stale: ?bool = null,
    cron_disabled: ?bool = null,
    cron_manual_tick: ?bool = null,
    env_base_url: ?[]u8 = null,
    env_oauth_host: ?[]u8 = null,
    log_level: ?[]u8 = null,
    log_global_max_bytes: ?usize = null,
    log_global_files: ?usize = null,
    log_session_max_bytes: ?usize = null,
    log_session_files: ?usize = null,
    browser_route: ?BrowserRoute = null,
    browser_birdman_host: ?[]u8 = null,
    browser_birdman_port: ?u16 = null,
    browser_birdman_path: ?[]u8 = null,
    model_env: ModelOverlay = .{},

    pub fn deinit(self: *Sections, alloc: Allocator) void {
        freeStringList(alloc, self.tools_enabled);
        freeStringList(alloc, self.tools_disabled);
        freeOwned(alloc, self.default_model);
        freeStringList(alloc, self.extra_skill_dirs);
        freeStringList(alloc, self.extra_agent_dirs);
        freeOwned(alloc, self.identity_name);
        freeOwned(alloc, self.output_style);
        freeOwned(alloc, self.identity_slug);
        self.services_moonshot_search.deinit(alloc);
        self.services_moonshot_fetch.deinit(alloc);
        freeFlags(alloc, self.experimental);
        freeOwned(alloc, self.secondary_model_default_model);
        freeOwned(alloc, self.secondary_model_default_effort);
        freePairs(alloc, self.secondary_model_models);
        freeModelAliases(alloc, self.model_aliases);
        freeOwned(alloc, self.thinking_keep);
        freeOwned(alloc, self.env_base_url);
        freeOwned(alloc, self.env_oauth_host);
        freeOwned(alloc, self.log_level);
        freeOwned(alloc, self.browser_birdman_host);
        freeOwned(alloc, self.browser_birdman_path);
        self.model_env.deinit(alloc);
        self.* = .{};
    }

    pub fn merge(self: *Sections, alloc: Allocator, incoming: *Sections) void {
        takeScalar(&self.browser_route, incoming.browser_route);
        takeOwned(alloc, &self.browser_birdman_host, &incoming.browser_birdman_host);
        takeScalar(&self.browser_birdman_port, incoming.browser_birdman_port);
        takeOwned(alloc, &self.browser_birdman_path, &incoming.browser_birdman_path);
        takeScalar(&self.read_default_max_chars, incoming.read_default_max_chars);
        takeScalar(&self.read_max_chars, incoming.read_max_chars);
        takeStringList(alloc, &self.tools_enabled, &incoming.tools_enabled);
        takeStringList(alloc, &self.tools_disabled, &incoming.tools_disabled);
        takeScalar(&self.default_plan_mode, incoming.default_plan_mode);
        takeOwned(alloc, &self.default_model, &incoming.default_model);
        takeScalar(&self.dangerous_command_guard, incoming.dangerous_command_guard);
        takeStringList(alloc, &self.extra_skill_dirs, &incoming.extra_skill_dirs);
        takeScalar(&self.merge_all_available_skills, incoming.merge_all_available_skills);
        takeScalar(&self.builtin_product_skills, incoming.builtin_product_skills);
        takeStringList(alloc, &self.extra_agent_dirs, &incoming.extra_agent_dirs);
        takeOwned(alloc, &self.identity_name, &incoming.identity_name);
        takeOwned(alloc, &self.output_style, &incoming.output_style);
        takeOwned(alloc, &self.identity_slug, &incoming.identity_slug);
        self.services_moonshot_search.merge(alloc, &incoming.services_moonshot_search);
        self.services_moonshot_fetch.merge(alloc, &incoming.services_moonshot_fetch);
        takeFlags(alloc, &self.experimental, &incoming.experimental);
        takeScalar(&self.swarm_timeout_ms, incoming.swarm_timeout_ms);
        takeScalar(&self.subagent_timeout_ms, incoming.subagent_timeout_ms);
        takeOwned(alloc, &self.secondary_model_default_model, &incoming.secondary_model_default_model);
        takeOwned(alloc, &self.secondary_model_default_effort, &incoming.secondary_model_default_effort);
        takePairs(alloc, &self.secondary_model_models, &incoming.secondary_model_models);
        takeModelAliases(alloc, &self.model_aliases, &incoming.model_aliases);
        takeScalar(&self.model_catalog_refresh_interval_ms, incoming.model_catalog_refresh_interval_ms);
        takeScalar(&self.model_catalog_refresh_on_start, incoming.model_catalog_refresh_on_start);
        takeScalar(&self.thinking_enabled, incoming.thinking_enabled);
        takeOwned(alloc, &self.thinking_keep, &incoming.thinking_keep);
        takeScalar(&self.image_max_edge_px, incoming.image_max_edge_px);
        takeScalar(&self.image_read_byte_budget, incoming.image_read_byte_budget);
        takeScalar(&self.loop_max_steps_per_turn, incoming.loop_max_steps_per_turn);
        takeScalar(&self.loop_max_attempts_per_step, incoming.loop_max_attempts_per_step);
        takeScalar(&self.loop_max_ralph_iterations, incoming.loop_max_ralph_iterations);
        takeScalar(&self.loop_reserved_context_size, incoming.loop_reserved_context_size);
        takeScalar(&self.loop_compaction_trigger_ratio, incoming.loop_compaction_trigger_ratio);
        takeScalar(&self.loop_compaction_max_attempts, incoming.loop_compaction_max_attempts);
        takeScalar(&self.mcp_startup_timeout_ms, incoming.mcp_startup_timeout_ms);
        takeScalar(&self.mcp_tool_timeout_ms, incoming.mcp_tool_timeout_ms);
        takeScalar(&self.mcp_default_deferred, incoming.mcp_default_deferred);
        takeScalar(&self.mcp_reconnect_initial_delay_ms, incoming.mcp_reconnect_initial_delay_ms);
        takeScalar(&self.mcp_reconnect_max_delay_ms, incoming.mcp_reconnect_max_delay_ms);
        takeScalar(&self.task_max_running_tasks, incoming.task_max_running_tasks);
        takeScalar(&self.task_keep_alive_on_exit, incoming.task_keep_alive_on_exit);
        takeScalar(&self.task_bash_auto_background_on_timeout, incoming.task_bash_auto_background_on_timeout);
        takeScalar(&self.task_bash_timeout_s, incoming.task_bash_timeout_s);
        takeScalar(&self.task_kill_grace_period_ms, incoming.task_kill_grace_period_ms);
        takeScalar(&self.task_stuck_after_s, incoming.task_stuck_after_s);
        takeScalar(&self.task_root_job_wait_s, incoming.task_root_job_wait_s);
        takeScalar(&self.task_root_min_free_mb, incoming.task_root_min_free_mb);
        takeScalar(&self.task_bash_output_max_chars, incoming.task_bash_output_max_chars);
        takeScalar(&self.task_background_disabled, incoming.task_background_disabled);
        takeScalar(&self.task_print_background_mode, incoming.task_print_background_mode);
        takeScalar(&self.task_print_max_turns, incoming.task_print_max_turns);
        takeScalar(&self.task_print_wait_ceiling_s, incoming.task_print_wait_ceiling_s);
        takeScalar(&self.database_base, incoming.database_base);
        takeScalar(&self.database_global_search, incoming.database_global_search);
        takeScalar(&self.database_search, incoming.database_search);
        takeScalar(&self.database_search_sync_session_cap, incoming.database_search_sync_session_cap);
        takeScalar(&self.database_search_sync_debounce_ms, incoming.database_search_sync_debounce_ms);
        takeScalar(&self.token_counting_strategy, incoming.token_counting_strategy);
        takeScalar(&self.workspace_require_trust, incoming.workspace_require_trust);
        takeScalar(&self.watch_enabled, incoming.watch_enabled);
        takeScalar(&self.cron_debug, incoming.cron_debug);
        takeScalar(&self.cron_no_jitter, incoming.cron_no_jitter);
        takeScalar(&self.cron_no_stale, incoming.cron_no_stale);
        takeScalar(&self.cron_disabled, incoming.cron_disabled);
        takeScalar(&self.cron_manual_tick, incoming.cron_manual_tick);
        takeOwned(alloc, &self.env_base_url, &incoming.env_base_url);
        takeOwned(alloc, &self.env_oauth_host, &incoming.env_oauth_host);
        takeOwned(alloc, &self.log_level, &incoming.log_level);
        takeScalar(&self.log_global_max_bytes, incoming.log_global_max_bytes);
        takeScalar(&self.log_global_files, incoming.log_global_files);
        takeScalar(&self.log_session_max_bytes, incoming.log_session_max_bytes);
        takeScalar(&self.log_session_files, incoming.log_session_files);
        takeModelOverlay(alloc, &self.model_env, &incoming.model_env);
        incoming.* = .{};
    }
};

pub fn parse(alloc: Allocator, root: std.json.Value) !Sections {
    var sections: Sections = .{};
    errdefer sections.deinit(alloc);

    if (root.object.get("default_plan_mode")) |value| sections.default_plan_mode = try boolField(value);
    if (root.object.get("default_model")) |value| sections.default_model = try stringField(alloc, value);
    if (root.object.get("output_style")) |value| sections.output_style = try stringField(alloc, value);
    if (root.object.get("dangerous_command_guard")) |value| sections.dangerous_command_guard = try boolField(value);
    if (permissionSectionGuard(root)) |guard| sections.dangerous_command_guard = guard;
    if (root.object.get("extra_skill_dirs")) |value| sections.extra_skill_dirs = try stringListField(alloc, value);
    if (root.object.get("merge_all_available_skills")) |value| sections.merge_all_available_skills = try boolField(value);
    if (root.object.get("builtin_product_skills")) |value| sections.builtin_product_skills = try boolField(value);
    if (root.object.get("extra_agent_dirs")) |value| sections.extra_agent_dirs = try stringListField(alloc, value);
    if (try optionalObject(root, "swarm")) |section| sections.swarm_timeout_ms = try timeoutMsField(section, "timeout_ms", 0);
    if (try optionalObject(root, "subagent")) |section| sections.subagent_timeout_ms = try timeoutMsField(section, "timeout_ms", 0);
    if (root.object.get("experimental")) |value| sections.experimental = try flagsField(alloc, value);

    if (try optionalObject(root, "read")) |section| {
        sections.read_default_max_chars = try positiveField(section, "default_max_chars");
        sections.read_max_chars = try positiveField(section, "max_chars");
    }
    if (try optionalObject(root, "tools")) |section| {
        if (section.object.get("enabled")) |value| sections.tools_enabled = try stringListField(alloc, value);
        if (section.object.get("disabled")) |value| sections.tools_disabled = try stringListField(alloc, value);
    }
    if (try optionalObject(root, "identity")) |section| {
        if (section.object.get("name")) |value| sections.identity_name = try stringField(alloc, value);
        if (section.object.get("slug")) |value| sections.identity_slug = try stringField(alloc, value);
    }
    if (try optionalObject(root, "services")) |section| {
        if (try optionalObject(section, "moonshot_search")) |service| sections.services_moonshot_search = try parseService(alloc, service);
        if (try optionalObject(section, "moonshot_fetch")) |service| sections.services_moonshot_fetch = try parseService(alloc, service);
    }
    if (try optionalObject(root, "secondary_model")) |section| {
        if (section.object.get("default_model")) |value| sections.secondary_model_default_model = try stringField(alloc, value);
        if (section.object.get("default_effort")) |value| sections.secondary_model_default_effort = try stringField(alloc, value);
        if (section.object.get("models")) |value| sections.secondary_model_models = try pairsField(alloc, value);
    }
    if (root.object.get("models")) |value| sections.model_aliases = try parseModelAliases(alloc, value);
    if (try optionalObject(root, "model_catalog")) |section| {
        if (section.object.get("refresh_interval_ms")) |value| sections.model_catalog_refresh_interval_ms = try usizeField(value, 0, max_timeout_ms);
        if (section.object.get("refresh_on_start")) |value| sections.model_catalog_refresh_on_start = try boolField(value);
    }
    if (try optionalObject(root, "thinking")) |section| {
        if (section.object.get("enabled")) |value| sections.thinking_enabled = try boolField(value);
        if (section.object.get("keep")) |value| sections.thinking_keep = try stringField(alloc, value);
    }
    if (try optionalObject(root, "image")) |section| {
        sections.image_max_edge_px = try positiveField(section, "max_edge_px");
        sections.image_read_byte_budget = try positiveField(section, "read_byte_budget");
    }
    if (try optionalObject(root, "browser")) |section| {
        if (section.object.get("route")) |value| sections.browser_route = try browserRouteField(value);
        if (try optionalObject(section, "birdman")) |birdman| {
            if (birdman.object.get("host")) |value| sections.browser_birdman_host = try browserTextField(alloc, value);
            if (birdman.object.get("port")) |value| sections.browser_birdman_port = try browserPortField(value);
            if (birdman.object.get("path")) |value| sections.browser_birdman_path = try browserPathField(alloc, value);
        }
    }
    if (try optionalObject(root, "loop_control")) |section| {
        if (section.object.get("max_steps_per_turn")) |value| sections.loop_max_steps_per_turn = try usizeField(value, 0, std.math.maxInt(i64));
        if (section.object.get("max_attempts_per_step")) |value| sections.loop_max_attempts_per_step = try usizeField(value, 0, std.math.maxInt(i64));
        if (section.object.get("max_ralph_iterations")) |value| sections.loop_max_ralph_iterations = try i64Field(value, -1, std.math.maxInt(i64));
        if (section.object.get("reserved_context_size")) |value| sections.loop_reserved_context_size = try usizeField(value, 0, std.math.maxInt(i64));
        if (section.object.get("compaction_trigger_ratio")) |value| sections.loop_compaction_trigger_ratio = try ratioField(value);
        if (section.object.get("compaction_max_attempts")) |value| sections.loop_compaction_max_attempts = try usizeField(value, 1, std.math.maxInt(i64));
    }
    if (try optionalObject(root, "mcp")) |section| {
        sections.mcp_startup_timeout_ms = try timeoutMsField(section, "startup_timeout_ms", 1);
        sections.mcp_tool_timeout_ms = try timeoutMsField(section, "tool_timeout_ms", 1);
        if (section.object.get("default_deferred")) |value| sections.mcp_default_deferred = try boolField(value);
        sections.mcp_reconnect_initial_delay_ms = try timeoutMsField(section, "reconnect_initial_delay_ms", 1);
        sections.mcp_reconnect_max_delay_ms = try timeoutMsField(section, "reconnect_max_delay_ms", 1);
    }
    if (try optionalObject(root, "task")) |section| {
        if (section.object.get("max_running_tasks")) |value| sections.task_max_running_tasks = try usizeField(value, 1, std.math.maxInt(i64));
        if (section.object.get("keep_alive_on_exit")) |value| sections.task_keep_alive_on_exit = try boolField(value);
        if (section.object.get("bash_auto_background_on_timeout")) |value| sections.task_bash_auto_background_on_timeout = try boolField(value);
        if (section.object.get("bash_task_timeout_s")) |value| sections.task_bash_timeout_s = try usizeField(value, 0, std.math.maxInt(i64));
        if (section.object.get("kill_grace_period_ms")) |value| sections.task_kill_grace_period_ms = try usizeField(value, 0, std.math.maxInt(i64));
        if (section.object.get("stuck_after_s")) |value| sections.task_stuck_after_s = try usizeField(value, 1, std.math.maxInt(i64));
        if (section.object.get("root_job_wait_s")) |value| sections.task_root_job_wait_s = try usizeField(value, 1, std.math.maxInt(i64));
        if (section.object.get("root_min_free_mb")) |value| sections.task_root_min_free_mb = try usizeField(value, 0, std.math.maxInt(i64));
        if (section.object.get("bash_output_max_chars")) |value| sections.task_bash_output_max_chars = try usizeField(value, 1, max_bash_output_chars);
        if (section.object.get("background_disabled")) |value| sections.task_background_disabled = try boolField(value);
        if (section.object.get("print_background_mode")) |value| {
            if (value != .string) return error.InvalidKimiSectionValue;
            sections.task_print_background_mode = PrintBackgroundMode.parse(value.string) orelse return error.InvalidKimiSectionValue;
        }
        if (section.object.get("print_max_turns")) |value| sections.task_print_max_turns = try usizeField(value, 1, std.math.maxInt(i64));
        if (section.object.get("print_wait_ceiling_s")) |value| sections.task_print_wait_ceiling_s = try usizeField(value, 1, std.math.maxInt(i64));
    }
    if (try optionalObject(root, "database")) |section| {
        if (section.object.get("base")) |value| sections.database_base = try boolField(value);
        if (section.object.get("global_search")) |value| sections.database_global_search = try boolField(value);
        if (section.object.get("search")) |value| sections.database_search = try boolField(value);
        if (section.object.get("search_sync_session_cap")) |value| sections.database_search_sync_session_cap = try usizeField(value, 1, std.math.maxInt(i64));
        if (section.object.get("search_sync_debounce_ms")) |value| sections.database_search_sync_debounce_ms = try usizeField(value, 0, std.math.maxInt(i64));
    }
    if (try optionalObject(root, "token_counting")) |section| {
        if (section.object.get("strategy")) |value| {
            if (value != .string) return error.InvalidKimiSectionValue;
            sections.token_counting_strategy = TokenCountingStrategy.parse(value.string) orelse return error.InvalidKimiSectionValue;
        }
    }
    if (try optionalObject(root, "workspace")) |section| {
        if (section.object.get("require_trust")) |value| sections.workspace_require_trust = try boolField(value);
    }
    if (try optionalObject(root, "watch")) |section| {
        if (section.object.get("enabled")) |value| sections.watch_enabled = try boolField(value);
    }
    if (try optionalObject(root, "cron")) |section| {
        if (section.object.get("debug")) |value| sections.cron_debug = try boolField(value);
        if (section.object.get("no_jitter")) |value| sections.cron_no_jitter = try boolField(value);
        if (section.object.get("no_stale")) |value| sections.cron_no_stale = try boolField(value);
        if (section.object.get("disabled")) |value| sections.cron_disabled = try boolField(value);
        if (section.object.get("manual_tick")) |value| sections.cron_manual_tick = try boolField(value);
    }
    return sections;
}

pub fn modelAliasFor(sections: *const Sections, name: []const u8) ?*const ModelAlias {
    const entries = sections.model_aliases orelse return null;
    for (entries) |*entry| {
        if (std.mem.eql(u8, entry.alias, name)) return entry;
    }
    for (entries) |*entry| {
        if (optionalEquals(entry.name, name) or optionalEquals(entry.model, name)) return entry;
        const aliases = entry.aliases orelse continue;
        if (containsString(aliases, name)) return entry;
    }
    return null;
}

pub fn experimentalEnabled(sections: *const Sections, name: []const u8) bool {
    if (experimentalConfigured(sections, name)) |enabled| return enabled;
    for (experimental_defaults) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.enabled;
    }
    return false;
}

pub fn experimentalConfigured(sections: *const Sections, name: []const u8) ?bool {
    const flags = sections.experimental orelse return null;
    for (flags) |flag| {
        if (std.mem.eql(u8, flag.name, name)) return flag.enabled;
    }
    return null;
}

fn optionalEquals(value: ?[]u8, needle: []const u8) bool {
    const text = value orelse return false;
    return std.mem.eql(u8, text, needle);
}

pub fn byteLimitForChars(text: []const u8, max_chars: usize) usize {
    var chars: usize = 0;
    for (text, 0..) |byte, index| {
        if ((byte & 0xC0) == 0x80) continue;
        if (chars == max_chars) return index;
        chars += 1;
    }
    return text.len;
}

pub fn toolAllowed(sections: *const Sections, name: []const u8) bool {
    if (sections.tools_enabled) |allowed| {
        if (!containsString(allowed, name)) return false;
    }
    if (sections.tools_disabled) |denied| {
        if (containsString(denied, name)) return false;
    }
    return true;
}

fn containsString(values: []const []u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn permissionSectionGuard(root: std.json.Value) ?bool {
    const permission = root.object.get("permission") orelse return null;
    if (permission != .object) return null;
    const guard = permission.object.get("dangerous_command_guard") orelse return null;
    return if (guard == .bool) guard.bool else null;
}

fn optionalObject(parent: std.json.Value, key: []const u8) Error!?std.json.Value {
    const value = parent.object.get(key) orelse return null;
    if (value != .object) return error.InvalidKimiSectionShape;
    return value;
}

fn boolField(value: std.json.Value) Error!bool {
    if (value != .bool) return error.InvalidKimiSectionValue;
    return value.bool;
}

fn usizeField(value: std.json.Value, min: i64, max: i64) Error!usize {
    if (value != .integer) return error.InvalidKimiSectionValue;
    if (value.integer < min or value.integer > max) return error.InvalidKimiSectionValue;
    return std.math.cast(usize, value.integer) orelse error.InvalidKimiSectionValue;
}

fn i64Field(value: std.json.Value, min: i64, max: i64) Error!i64 {
    if (value != .integer) return error.InvalidKimiSectionValue;
    if (value.integer < min or value.integer > max) return error.InvalidKimiSectionValue;
    return value.integer;
}

fn positiveField(section: std.json.Value, key: []const u8) Error!?usize {
    const value = section.object.get(key) orelse return null;
    return try usizeField(value, 1, std.math.maxInt(i64));
}

fn timeoutMsField(section: std.json.Value, key: []const u8, min: i64) Error!?usize {
    const value = section.object.get(key) orelse return null;
    return try usizeField(value, min, max_timeout_ms);
}

fn ratioField(value: std.json.Value) Error!f64 {
    const ratio: f64 = switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return error.InvalidKimiSectionValue,
    };
    if (ratio < 0.5 or ratio > 0.99) return error.InvalidKimiSectionValue;
    return ratio;
}

fn stringField(alloc: Allocator, value: std.json.Value) !?[]u8 {
    if (value != .string) return error.InvalidKimiSectionValue;
    return try alloc.dupe(u8, value.string);
}

fn stringListField(alloc: Allocator, value: std.json.Value) !?[][]u8 {
    if (value != .array) return error.InvalidKimiSectionValue;
    const items = value.array.items;
    const list = try alloc.alloc([]u8, items.len);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |item| alloc.free(item);
        alloc.free(list);
    }
    for (items) |item| {
        if (item != .string) return error.InvalidKimiSectionValue;
        list[filled] = try alloc.dupe(u8, item.string);
        filled += 1;
    }
    return list;
}

fn pairsField(alloc: Allocator, value: std.json.Value) !?[]Pair {
    if (value != .object) return error.InvalidKimiSectionValue;
    var list: std.ArrayList(Pair) = .empty;
    errdefer {
        for (list.items) |pair| {
            alloc.free(pair.name);
            alloc.free(pair.value);
        }
        list.deinit(alloc);
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.InvalidKimiSectionValue;
        const name = try alloc.dupe(u8, entry.key_ptr.*);
        errdefer alloc.free(name);
        const text = try alloc.dupe(u8, entry.value_ptr.*.string);
        errdefer alloc.free(text);
        try list.append(alloc, .{ .name = name, .value = text });
    }
    return try list.toOwnedSlice(alloc);
}

fn flagsField(alloc: Allocator, value: std.json.Value) !?[]Flag {
    if (value != .object) return error.InvalidKimiSectionValue;
    var list: std.ArrayList(Flag) = .empty;
    errdefer {
        for (list.items) |flag| alloc.free(flag.name);
        list.deinit(alloc);
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .bool) return error.InvalidKimiSectionValue;
        const name = try alloc.dupe(u8, entry.key_ptr.*);
        errdefer alloc.free(name);
        try list.append(alloc, .{ .name = name, .enabled = entry.value_ptr.*.bool });
    }
    return try list.toOwnedSlice(alloc);
}

const protocol_names = [_][]const u8{ "anthropic", "openai", "openai_responses", "google-genai" };

fn isProtocolName(text: []const u8) bool {
    for (protocol_names) |name| {
        if (std.mem.eql(u8, name, text)) return true;
    }
    return false;
}

fn parseModelAliases(alloc: Allocator, value: std.json.Value) !?[]ModelAlias {
    if (value != .object) return null;
    var list: std.ArrayList(ModelAlias) = .empty;
    errdefer {
        for (list.items) |*entry| entry.deinit(alloc);
        list.deinit(alloc);
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        var model = try parseModelAlias(alloc, entry.key_ptr.*, entry.value_ptr.*);
        errdefer model.deinit(alloc);
        if (model.model == null and model.name == null) {
            model.deinit(alloc);
            continue;
        }
        try list.append(alloc, model);
    }
    return try list.toOwnedSlice(alloc);
}

fn parseModelAlias(alloc: Allocator, alias: []const u8, value: std.json.Value) !ModelAlias {
    var model: ModelAlias = .{ .alias = try alloc.dupe(u8, alias) };
    errdefer model.deinit(alloc);
    if (value.object.get("provider")) |field| model.provider = try stringField(alloc, field);
    if (value.object.get("model")) |field| model.model = try stringField(alloc, field);
    if (value.object.get("name")) |field| model.name = try stringField(alloc, field);
    if (value.object.get("protocol")) |field| {
        model.protocol = try stringField(alloc, field);
        if (!isProtocolName(model.protocol.?)) return error.InvalidKimiSectionValue;
    }
    if (value.object.get("aliases")) |field| model.aliases = try stringListField(alloc, field);
    if (value.object.get("provider_id")) |field| model.provider_id = try stringField(alloc, field);
    if (value.object.get("base_url")) |field| model.base_url = try stringField(alloc, field);
    if (value.object.get("api_key")) |field| model.api_key = try stringField(alloc, field);
    if (value.object.get("beta_api")) |field| model.beta_api = try boolField(field);
    model.limits = try parseLimits(alloc, value);
    if (value.object.get("overrides")) |field| {
        if (field != .object) return error.InvalidKimiSectionShape;
        model.overrides = try parseLimits(alloc, field);
    }
    return model;
}

fn parseLimits(alloc: Allocator, value: std.json.Value) !Limits {
    var limits: Limits = .{};
    errdefer limits.deinit(alloc);
    if (value.object.get("max_context_size")) |field| limits.max_context_size = try usizeField(field, 1, std.math.maxInt(i64));
    if (value.object.get("max_input_size")) |field| limits.max_input_size = try usizeField(field, 1, std.math.maxInt(i64));
    if (value.object.get("max_output_size")) |field| limits.max_output_size = try usizeField(field, 1, std.math.maxInt(i64));
    if (value.object.get("capabilities")) |field| limits.capabilities = try stringListField(alloc, field);
    if (value.object.get("display_name")) |field| limits.display_name = try stringField(alloc, field);
    if (value.object.get("reasoning_key")) |field| limits.reasoning_key = try stringField(alloc, field);
    if (value.object.get("adaptive_thinking")) |field| limits.adaptive_thinking = try boolField(field);
    if (value.object.get("support_efforts")) |field| limits.support_efforts = try stringListField(alloc, field);
    if (value.object.get("default_effort")) |field| limits.default_effort = try stringField(alloc, field);
    if (value.object.get("off_effort")) |field| limits.off_effort = try stringField(alloc, field);
    return limits;
}

fn freeModelAliases(alloc: Allocator, value: ?[]ModelAlias) void {
    const items = value orelse return;
    for (items) |*entry| entry.deinit(alloc);
    alloc.free(items);
}

fn takeModelAliases(alloc: Allocator, slot: *?[]ModelAlias, incoming: *?[]ModelAlias) void {
    const next = incoming.* orelse return;
    freeModelAliases(alloc, slot.*);
    slot.* = next;
    incoming.* = null;
}

fn parseService(alloc: Allocator, value: std.json.Value) !Service {
    var service: Service = .{};
    errdefer service.deinit(alloc);
    if (value.object.get("base_url")) |base_url| service.base_url = try stringField(alloc, base_url);
    if (value.object.get("api_key")) |api_key| service.api_key = try stringField(alloc, api_key);
    return service;
}

fn freeOwned(alloc: Allocator, value: ?[]u8) void {
    if (value) |text| alloc.free(text);
}

fn freeStringList(alloc: Allocator, value: ?[][]u8) void {
    const items = value orelse return;
    for (items) |item| alloc.free(item);
    alloc.free(items);
}

fn freePairs(alloc: Allocator, value: ?[]Pair) void {
    const items = value orelse return;
    for (items) |pair| {
        alloc.free(pair.name);
        alloc.free(pair.value);
    }
    alloc.free(items);
}

fn freeFlags(alloc: Allocator, value: ?[]Flag) void {
    const items = value orelse return;
    for (items) |flag| alloc.free(flag.name);
    alloc.free(items);
}

fn takeScalar(slot: anytype, incoming: anytype) void {
    if (incoming) |value| slot.* = value;
}

fn takeOwned(alloc: Allocator, slot: *?[]u8, incoming: *?[]u8) void {
    const next = incoming.* orelse return;
    freeOwned(alloc, slot.*);
    slot.* = next;
    incoming.* = null;
}

fn takeStringList(alloc: Allocator, slot: *?[][]u8, incoming: *?[][]u8) void {
    const next = incoming.* orelse return;
    freeStringList(alloc, slot.*);
    slot.* = next;
    incoming.* = null;
}

fn takePairs(alloc: Allocator, slot: *?[]Pair, incoming: *?[]Pair) void {
    const next = incoming.* orelse return;
    freePairs(alloc, slot.*);
    slot.* = next;
    incoming.* = null;
}

fn takeFlags(alloc: Allocator, slot: *?[]Flag, incoming: *?[]Flag) void {
    const next = incoming.* orelse return;
    freeFlags(alloc, slot.*);
    slot.* = next;
    incoming.* = null;
}

fn takeModelOverlay(alloc: Allocator, slot: *ModelOverlay, incoming: *ModelOverlay) void {
    takeOwned(alloc, &slot.api_key, &incoming.api_key);
    takeOwned(alloc, &slot.provider_type, &incoming.provider_type);
    takeOwned(alloc, &slot.base_url, &incoming.base_url);
    takeOwned(alloc, &slot.name, &incoming.name);
    takeOwned(alloc, &slot.thinking_effort, &incoming.thinking_effort);
    takeOwned(alloc, &slot.thinking_keep, &incoming.thinking_keep);
    takeScalar(&slot.temperature, incoming.temperature);
    takeScalar(&slot.top_p, incoming.top_p);
    takeScalar(&slot.max_tokens, incoming.max_tokens);
    takeScalar(&slot.max_context_size, incoming.max_context_size);
    takeScalar(&slot.max_output_size, incoming.max_output_size);
}

test "kimi sections parse read caps tools lists and plan mode default" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"default_plan_mode":true,"read":{"max_chars":4000},"tools":{"enabled":["Bash","Read"],"disabled":["Bash"]}}
    , .{});
    defer parsed.deinit();
    var sections = try parse(std.testing.allocator, parsed.value);
    defer sections.deinit(std.testing.allocator);
    try std.testing.expectEqual(true, sections.default_plan_mode.?);
    try std.testing.expectEqual(@as(usize, 4000), sections.read_max_chars.?);
    try std.testing.expect(sections.read_default_max_chars == null);
    try std.testing.expectEqual(@as(usize, 2), sections.tools_enabled.?.len);
}

test "the permission section's dangerous_command_guard is honoured and wins over the root key" {
    const cases = [_]struct { json: []const u8, guard: ?bool }{
        .{ .json = "{\"permission\":{\"dangerous_command_guard\":false}}", .guard = false },
        .{ .json = "{\"dangerous_command_guard\":true,\"permission\":{\"dangerous_command_guard\":false}}", .guard = false },
        .{ .json = "{\"dangerous_command_guard\":false,\"permission\":{\"allow\":[\"Read\"]}}", .guard = false },
        .{ .json = "{\"permission\":\"ask\"}", .guard = null },
        .{ .json = "{\"permission\":{\"dangerous_command_guard\":\"allow\"}}", .guard = null },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case.json, .{});
        defer parsed.deinit();
        var sections = try parse(std.testing.allocator, parsed.value);
        defer sections.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.guard, sections.dangerous_command_guard);
    }
}

test "kimi sections default to unset when absent" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer parsed.deinit();
    var sections = try parse(std.testing.allocator, parsed.value);
    defer sections.deinit(std.testing.allocator);
    try std.testing.expect(sections.default_plan_mode == null);
    try std.testing.expect(sections.read_max_chars == null);
    try std.testing.expect(sections.workspace_require_trust == null);
    try std.testing.expect(sections.token_counting_strategy == null);
}

test "kimi sections reject out of range and mistyped values" {
    const cases = [_][]const u8{
        "{\"read\":{\"max_chars\":0}}",
        "{\"read\":{\"max_chars\":\"many\"}}",
        "{\"mcp\":{\"startup_timeout_ms\":0}}",
        "{\"loop_control\":{\"compaction_trigger_ratio\":0.2}}",
        "{\"loop_control\":{\"compaction_trigger_ratio\":1.0}}",
        "{\"loop_control\":{\"max_ralph_iterations\":-2}}",
        "{\"token_counting\":{\"strategy\":\"exact\"}}",
        "{\"task\":{\"max_running_tasks\":0}}",
        "{\"default_plan_mode\":\"yes\"}",
        "{\"models\":{\"x\":{\"model\":\"m\",\"protocol\":\"smtp\"}}}",
    };
    for (cases) |text| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidKimiSectionValue, parseAndDrop(std.testing.allocator, parsed.value));
    }
    var shaped = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"read\":3}", .{});
    defer shaped.deinit();
    try std.testing.expectError(error.InvalidKimiSectionShape, parseAndDrop(std.testing.allocator, shaped.value));
}

pub fn browserEndpoint(sections: *const Sections) Error!BrowserEndpoint {
    var endpoint: BrowserEndpoint = .{};
    if (sections.browser_route) |route| endpoint.route = route;
    if (sections.browser_birdman_host) |host| try endpoint.host.set(host);
    if (sections.browser_birdman_port) |port| endpoint.port = port;
    if (sections.browser_birdman_path) |path| try endpoint.path.set(path);
    return endpoint;
}

fn browserRouteField(value: std.json.Value) Error!BrowserRoute {
    if (value != .string) return error.InvalidKimiSectionValue;
    return std.meta.stringToEnum(BrowserRoute, value.string) orelse error.InvalidKimiSectionValue;
}

fn browserPortField(value: std.json.Value) Error!u16 {
    return @intCast(try usizeField(value, 1, std.math.maxInt(u16)));
}

fn browserTextField(alloc: Allocator, value: std.json.Value) ![]u8 {
    if (value != .string) return error.InvalidKimiSectionValue;
    if (value.string.len == 0 or value.string.len > browser_endpoint_max_bytes) return error.InvalidKimiSectionValue;
    return try alloc.dupe(u8, value.string);
}

fn browserPathField(alloc: Allocator, value: std.json.Value) ![]u8 {
    if (value != .string or value.string.len == 0 or value.string[0] != '/') return error.InvalidKimiSectionValue;
    return browserTextField(alloc, value);
}

fn parseAndDrop(alloc: Allocator, root: std.json.Value) !void {
    var sections = try parse(alloc, root);
    sections.deinit(alloc);
}

test "byteLimitForChars counts code points rather than bytes" {
    try std.testing.expectEqual(@as(usize, 0), byteLimitForChars("héllo", 0));
    try std.testing.expectEqual(@as(usize, 3), byteLimitForChars("héllo", 2));
    try std.testing.expectEqual(@as(usize, 6), byteLimitForChars("héllo", 5));
    try std.testing.expectEqual(@as(usize, 6), byteLimitForChars("héllo", 99));
    try std.testing.expectEqual(@as(usize, 0), byteLimitForChars("", 3));
}

test "tool filter follows Kimi allow and deny semantics" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"tools":{"enabled":["Read","Grep"],"disabled":["Grep"]}}
    , .{});
    defer parsed.deinit();
    var sections = try parse(std.testing.allocator, parsed.value);
    defer sections.deinit(std.testing.allocator);
    try std.testing.expect(toolAllowed(&sections, "Read"));
    try std.testing.expect(!toolAllowed(&sections, "Grep"));
    try std.testing.expect(!toolAllowed(&sections, "Bash"));

    var unrestricted: Sections = .{};
    try std.testing.expect(toolAllowed(&unrestricted, "Bash"));
}

test "kimi sections merge keeps unset fields and replaces owned values" {
    var base_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"identity":{"name":"old"},"workspace":{"require_trust":false},"experimental":{"wait_for":true}}
    , .{});
    defer base_json.deinit();
    var target = try parse(std.testing.allocator, base_json.value);
    defer target.deinit(std.testing.allocator);

    var incoming_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"identity":{"name":"new"},"cron":{"disabled":true}}
    , .{});
    defer incoming_json.deinit();
    var incoming = try parse(std.testing.allocator, incoming_json.value);
    defer incoming.deinit(std.testing.allocator);

    target.merge(std.testing.allocator, &incoming);
    try std.testing.expectEqualStrings("new", target.identity_name.?);
    try std.testing.expectEqual(false, target.workspace_require_trust.?);
    try std.testing.expectEqual(true, target.cron_disabled.?);
    try std.testing.expectEqual(true, target.experimental.?[0].enabled);
}

test "browser endpoint keeps the Birdman defaults when absent and reads a configured target" {
    var empty = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer empty.deinit();
    var absent = try parse(std.testing.allocator, empty.value);
    defer absent.deinit(std.testing.allocator);
    const defaults = try browserEndpoint(&absent);
    try std.testing.expectEqual(BrowserRoute.birdman, defaults.route);
    try std.testing.expectEqualStrings("127.0.0.1", defaults.host.slice());
    try std.testing.expectEqual(@as(u16, 19999), defaults.port);
    try std.testing.expectEqualStrings("/devtools/browser/birdman", defaults.path.slice());

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"browser":{"route":"cdp","birdman":{"host":"10.0.0.5","port":9222,"path":"/x/birdman"}}}
    , .{});
    defer parsed.deinit();
    var sections = try parse(std.testing.allocator, parsed.value);
    defer sections.deinit(std.testing.allocator);
    const endpoint = try browserEndpoint(&sections);
    try std.testing.expectEqual(BrowserRoute.cdp, endpoint.route);
    try std.testing.expectEqualStrings("10.0.0.5", endpoint.host.slice());
    try std.testing.expectEqual(@as(u16, 9222), endpoint.port);
    try std.testing.expectEqualStrings("/x/birdman", endpoint.path.slice());
}

test "browser endpoint rejects unknown routes, out of range ports and relative paths" {
    const cases = [_][]const u8{
        "{\"browser\":{\"route\":\"firefox\"}}",
        "{\"browser\":{\"birdman\":{\"port\":0}}}",
        "{\"browser\":{\"birdman\":{\"port\":65536}}}",
        "{\"browser\":{\"birdman\":{\"path\":\"devtools\"}}}",
        "{\"browser\":{\"birdman\":{\"host\":\"\"}}}",
    };
    for (cases) |text| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidKimiSectionValue, parse(std.testing.allocator, parsed.value));
    }
}

test "kimi sections parse loop, mcp, task, and token counting keys" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"loop_control":{"max_steps_per_turn":40,"compaction_trigger_ratio":0.75,"max_ralph_iterations":-1},"mcp":{"startup_timeout_ms":5000,"default_deferred":true},"task":{"bash_auto_background_on_timeout":false,"max_running_tasks":3},"token_counting":{"strategy":"measured"}}
    , .{});
    defer parsed.deinit();
    var sections = try parse(std.testing.allocator, parsed.value);
    defer sections.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 40), sections.loop_max_steps_per_turn.?);
    try std.testing.expectEqual(@as(f64, 0.75), sections.loop_compaction_trigger_ratio.?);
    try std.testing.expectEqual(@as(i64, -1), sections.loop_max_ralph_iterations.?);
    try std.testing.expectEqual(@as(usize, 5000), sections.mcp_startup_timeout_ms.?);
    try std.testing.expectEqual(true, sections.mcp_default_deferred.?);
    try std.testing.expectEqual(false, sections.task_bash_auto_background_on_timeout.?);
    try std.testing.expectEqual(@as(usize, 3), sections.task_max_running_tasks.?);
    try std.testing.expectEqual(TokenCountingStrategy.measured, sections.token_counting_strategy.?);
}

test "kimi sections parse the print background mode, turn limit and wait ceiling of the task section" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"task":{"print_background_mode":"drain","print_max_turns":7,"print_wait_ceiling_s":30}}
    , .{});
    defer parsed.deinit();
    var sections = try parse(std.testing.allocator, parsed.value);
    defer sections.deinit(std.testing.allocator);
    try std.testing.expectEqual(PrintBackgroundMode.drain, sections.task_print_background_mode.?);
    try std.testing.expectEqual(@as(usize, 7), sections.task_print_max_turns.?);
    try std.testing.expectEqual(@as(usize, 30), sections.task_print_wait_ceiling_s.?);

    var unknown_mode = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"task":{"print_background_mode":"linger"}}
    , .{});
    defer unknown_mode.deinit();
    try std.testing.expectError(error.InvalidKimiSectionValue, parse(std.testing.allocator, unknown_mode.value));
}

test "kimi sections parse the task stuck threshold and merge it over an earlier layer" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"task":{"stuck_after_s":45,"kill_grace_period_ms":250,"root_job_wait_s":90,"root_min_free_mb":64,"bash_output_max_chars":8000,"background_disabled":true}}
    , .{});
    defer parsed.deinit();
    var sections = try parse(std.testing.allocator, parsed.value);
    defer sections.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 45), sections.task_stuck_after_s.?);
    try std.testing.expectEqual(@as(usize, 90), sections.task_root_job_wait_s.?);
    try std.testing.expectEqual(@as(usize, 64), sections.task_root_min_free_mb.?);
    try std.testing.expectEqual(@as(usize, 8000), sections.task_bash_output_max_chars.?);
    try std.testing.expect(sections.task_background_disabled.?);
    try std.testing.expectEqual(@as(usize, 250), sections.task_kill_grace_period_ms.?);

    var base: Sections = .{ .task_stuck_after_s = 180 };
    defer base.deinit(std.testing.allocator);
    base.merge(std.testing.allocator, &sections);
    try std.testing.expectEqual(@as(usize, 45), base.task_stuck_after_s.?);

    var zero = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"task":{"stuck_after_s":0}}
    , .{});
    defer zero.deinit();
    try std.testing.expectError(error.InvalidKimiSectionValue, parseAndDrop(std.testing.allocator, zero.value));
}

test "kimi sections parse skill and agent directories with service and model tables" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"extra_skill_dirs":["/opt/skills"],"merge_all_available_skills":false,"builtin_product_skills":true,"extra_agent_dirs":["/opt/agents"],"default_model":"kimi-k2","services":{"moonshot_search":{"base_url":"https://search.example","api_key":"k1"}},"secondary_model":{"default_model":"small","default_effort":"low","models":{"review":"small-2"}}}
    , .{});
    defer parsed.deinit();
    var sections = try parse(std.testing.allocator, parsed.value);
    defer sections.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/opt/skills", sections.extra_skill_dirs.?[0]);
    try std.testing.expectEqual(false, sections.merge_all_available_skills.?);
    try std.testing.expectEqualStrings("kimi-k2", sections.default_model.?);
    try std.testing.expectEqualStrings("k1", sections.services_moonshot_search.api_key.?);
    try std.testing.expectEqualStrings("small-2", sections.secondary_model_models.?[0].value);
    try std.testing.expectEqualStrings("low", sections.secondary_model_default_effort.?);
}

test "kimi sections parse model alias tables and skip the provider map entries" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"models":{"gateway":"gpt-5","fast":{"provider":"gateway","model":"gpt-5-mini","protocol":"openai","aliases":["mini"],"max_context_size":128000,"capabilities":["image_in"],"beta_api":true,"overrides":{"display_name":"Mini"}},"nameless":{"provider":"x"}}}
    , .{});
    defer parsed.deinit();
    var sections = try parse(std.testing.allocator, parsed.value);
    defer sections.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), sections.model_aliases.?.len);
    const fast = modelAliasFor(&sections, "fast").?;
    try std.testing.expectEqualStrings("gpt-5-mini", fast.model.?);
    try std.testing.expectEqual(@as(usize, 128000), fast.limits.max_context_size.?);
    try std.testing.expectEqualStrings("image_in", fast.limits.capabilities.?[0]);
    try std.testing.expectEqualStrings("Mini", fast.overrides.display_name.?);
    try std.testing.expectEqual(true, fast.beta_api.?);
    try std.testing.expectEqualStrings("fast", modelAliasFor(&sections, "mini").?.alias);
    try std.testing.expect(modelAliasFor(&sections, "nameless") == null);
}

test "experimental flags follow Kimi defaults and config overrides" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"experimental":{"tower":true,"wait_for":false}}
    , .{});
    defer parsed.deinit();
    var sections = try parse(std.testing.allocator, parsed.value);
    defer sections.deinit(std.testing.allocator);
    try std.testing.expect(!experimentalEnabled(&sections, "wait_for"));
    try std.testing.expect(experimentalEnabled(&sections, "tower"));
    try std.testing.expect(!experimentalEnabled(&sections, "tool_select"));
    var unset: Sections = .{};
    try std.testing.expect(experimentalEnabled(&unset, "wait_for"));
    try std.testing.expect(!experimentalEnabled(&unset, "notify_user"));
}
