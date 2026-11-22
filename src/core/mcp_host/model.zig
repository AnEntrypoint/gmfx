const std = @import("std");
const runtime_mod = @import("runtime.zig");
const config = @import("config.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const context_limits = @import("../config/context_limits.zig");
const permissions = @import("../permissions/permissions.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const tool_runtime = @import("../tooling/tool_runtime.zig");
const access_policy = @import("../mcp/access_policy.zig");
const catalog_state = @import("../mcp/catalog_state.zig");
const model_catalog = @import("../mcp/model_catalog.zig");
const selected_schema = @import("../mcp/selected_schema.zig");
const tool_names = @import("../mcp/tool_names.zig");
const tool_result = @import("../mcp/tool_result.zig");
const tool_search = @import("../mcp/tool_search.zig");
const tools_feature = @import("../mcp/features/tools.zig");
const elicitation = @import("../mcp/elicitation.zig");

const Allocator = std.mem.Allocator;
const Runtime = runtime_mod.Runtime;
const McpTool = catalog_state.McpTool;
const Access = tool_mcp_runtime.Access;
const Binding = tool_mcp_runtime.Binding;
const Cancel = ?*std.atomic.Value(bool);

pub const Catalog = struct {
    gpa: Allocator,
    io: std.Io,
    runtime: *Runtime,
    builtins: tool_dispatch.Registry,
    generation: std.atomic.Value(u32),
    names: tool_names.Registry,
    mutex: std.Io.Mutex = .init,
    servers: []const config.Server,
    lists: []List,
    serials: u64 = 0,

    const List = struct {
        token: u64,
        arena: ?std.heap.ArenaAllocator = null,
        tools: []McpTool = &.{},
        digest: ?[32]u8 = null,
        generation: u64 = 0,
        epoch: u64 = 0,
        state: enum { unknown, loaded, needs_login, failed } = .unknown,
        failure: ?[]u8 = null,

        fn offersTools(l: List) bool {
            return l.state == .loaded or (l.state == .needs_login and l.tools.len > 0);
        }
    };

    const Found = struct { server: usize, tool: *const McpTool };

    pub fn init(c: *Catalog, gpa: Allocator, io: std.Io, runtime: *Runtime, builtins: tool_dispatch.Registry) Allocator.Error!void {
        const servers = runtime.servers();
        const lists = try gpa.alloc(List, servers.len);
        const now: u96 = @bitCast(std.Io.Clock.real.now(io).nanoseconds);
        c.* = .{
            .gpa = gpa,
            .io = io,
            .runtime = runtime,
            .builtins = builtins,
            .generation = .init(@as(u32, @truncate(now)) | 1),
            .names = .init(gpa),
            .servers = servers,
            .lists = lists,
        };
        for (lists) |*l| l.* = .{ .token = c.serial() };
    }

    pub fn deinit(c: *Catalog) void {
        for (c.lists) |*l| freeList(c.gpa, l);
        c.gpa.free(c.lists);
        c.names.deinit();
        c.* = undefined;
    }

    pub fn reload(c: *Catalog, done: runtime_mod.Reloaded) Allocator.Error!void {
        const servers = c.runtime.servers();
        std.debug.assert(servers.len == done.kept.len);
        const lists = try c.gpa.alloc(List, servers.len);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (servers, done.kept, lists) |s, kept, *l| {
            l.* = .{ .token = c.serial() };
            if (!kept) continue;
            for (c.servers, c.lists) |old, *from| if (from.token != 0 and std.mem.eql(u8, old.name, s.name)) {
                l.* = from.*;
                from.token = 0;
                break;
            };
        }
        for (c.lists) |*l| if (l.token != 0) freeList(c.gpa, l);
        c.gpa.free(c.lists);
        c.servers = servers;
        c.lists = lists;
        if (done.dropped) _ = c.generation.fetchAdd(2, .acq_rel);
    }

    fn currentGeneration(c: *const Catalog) u64 {
        return c.generation.load(.acquire);
    }

    fn freeList(gpa: Allocator, l: *List) void {
        if (l.arena) |*arena| arena.deinit();
        if (l.failure) |why| gpa.free(why);
    }

    fn serial(c: *Catalog) u64 {
        c.serials += 1;
        return c.serials;
    }

    fn currentServers(c: *Catalog) []const config.Server {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        return c.servers;
    }

    fn indexLocked(c: *const Catalog, name: []const u8) ?usize {
        for (c.servers, 0..) |s, i| if (std.mem.eql(u8, s.name, name)) return i;
        return null;
    }

    fn listLocked(c: *Catalog, name: []const u8, token: u64) ?*List {
        const l = &c.lists[c.indexLocked(name) orelse return null];
        return if (l.token == token) l else null;
    }

    pub fn runtimeCapabilities(c: *Catalog) tool_mcp_runtime.RuntimeCapabilities {
        return .{ .context = c, .has_tool = hasToolFn, .validate_tool = validateToolFn, .call_tool = callToolFn };
    }

    pub fn wire(c: *Catalog, tc: *tool_runtime.Context) void {
        tc.mcp_ctx = c;
        tc.mcp_has_tool = hasToolFn;
        tc.mcp_validate_tool = validateToolFn;
        tc.mcp_call_tool = callToolFn;
        tc.mcp_search_tools = searchToolsFn;
        tc.mcp_tool_schema = toolSchemaFn;
        tc.mcp_list_tools = listToolsFn;
        tc.mcp_snapshot_tool = snapshotToolFn;
        tc.mcp_read_resource = readResourceFn;
    }

    pub fn hasTool(c: *Catalog, name: []const u8, access: Access) bool {
        if (!c.mayAllow(access)) return false;
        c.ensure(name, null) catch return false;
        return c.allows(access, name);
    }

    pub fn validateTool(c: *Catalog, arena: Allocator, name: []const u8, arguments_json: []const u8, access: Access) !tool_mcp_runtime.ValidationResult {
        if (!c.mayAllow(access)) return .not_available;
        try c.ensure(name, null);
        if (!c.allows(access, name)) return .not_available;
        tools_feature.validateArguments(arena, arguments_json, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .invalid = try arena.print("Invalid arguments for MCP tool {s}: {s}", .{ name, @errorName(err) }) };
        };
        return .{ .valid = c.currentGeneration() };
    }

    pub fn callTool(
        c: *Catalog,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
        max_tool_result_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
    ) !?tool_mcp_runtime.CallResult {
        if (!c.mayAllow(options.access)) return error.McpAccessDenied;
        if (options.expected_binding) |b| if (b.runtime_generation != c.currentGeneration()) return error.McpAdvertisedToolChanged;
        if (options.expected_runtime_generation) |g| if (g != c.currentGeneration()) return error.McpAuthorityChanged;
        try c.ensureCurrent(name, options.cancel_flag);
        const server, const tool, const transport, const how, const output_schema, const authenticating, const sign_in_tool = found: {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            const found = c.findLocked(name) orelse return null;
            if (!c.allowsLocked(options.access, found.server, name)) return error.McpAccessDenied;
            if (options.expected_binding) |b| {
                if (!b.sameDefinition(c.bindingLocked(found.server, found.tool.*))) return error.McpAdvertisedToolChanged;
            }
            const s = c.servers[found.server];
            if (s.held == .removed) return .{
                .model_output = try tool_result_limits.prepareModelOutput(arena, name, try removedServerNotice(arena, name), max_tool_result_bytes),
                .status = .tool_failure,
            };
            break :found .{
                s.name,
                try arena.dupe(u8, found.tool.original_name),
                @tagName(s.transport),
                signIn(c.runtime.options.slash_commands, s.source),
                found.tool.output_schema_json != null,
                c.lists[found.server].state == .needs_login,
                if (signsInByTool(s)) try c.authenticateToolName(arena, s.name) else null,
            };
        };
        if (authenticating) return try c.authenticate(arena, server, name, max_tool_result_bytes, options);
        var asking: Asking = .{ .responder = options.input_responder orelse undefined, .tool = name, .cancel = options.cancel_flag, .io = c.io };
        const observed = if (options.observer) |observer| observer.beginMcp(.{ .call_id = options.call_id, .server = server, .tool = tool, .transport = transport }) else null;
        const asker: ?runtime_mod.Asker = if (options.input_responder != null) .{ .context = &asking, .ask = Asking.ask } else null;
        const answer = c.runtime.callObserved(arena, server, tool, arguments_json, options.cancel_flag, asker, options.progress, observed) catch |err| {
            if (observed) |call| call.end(if (err == error.Cancelled) .cancelled else .failure, @errorName(err));
            asking.finish(arena, .abandoned);
            return err;
        };

        asking.finish(arena, if (answer == .result) .completed else .abandoned);
        if (answer == .ended and answer.ended.outcome == .needs_auth) c.refresh(server, null) catch |err| {
            debug_trace.logf("mcp", "MCP authenticate tool not offered server={s} err={s}", .{ server, @errorName(err) });
        };
        const result_limit_bytes = tool_result.outputLimitBytes(max_tool_result_bytes, io_mod.getenv(tool_result.output_tokens_env));
        const result = render(arena, server, name, tool, answer, result_limit_bytes, how, output_schema, sign_in_tool) catch |err| {
            if (observed) |call| call.end(.failure, @errorName(err));
            return err;
        };
        if (observed) |call| call.end(if (result) |value| value.status.observed() else .unavailable, null);
        return result;
    }

    pub fn readResource(
        c: *Catalog,
        arena: Allocator,
        server: []const u8,
        op: mcp_resources.Op,
        access: Access,
        cancel: Cancel,
    ) !tool_mcp_runtime.ResourceResult {
        if (!c.mayAllow(access)) return error.McpAccessDenied;
        return switch (try c.runtime.resource(arena, server, op, cancel)) {
            .result => |raw| .{ .result = raw },
            .failure => |f| .{ .failure = .{ .code = f.code, .message = f.message } },
            .ended => |e| .{ .ended = @tagName(e.outcome) },
            .unknown_server => .unknown_server,
        };
    }

    pub fn searchTools(
        c: *Catalog,
        alloc: Allocator,
        request: tool_mcp_runtime.SearchRequest,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: Access,
        cancel: Cancel,
    ) !tool_mcp_runtime.SearchResult {
        const servers = c.currentServers();
        if (request.server) |name| {
            for (servers) |s| {
                if (std.mem.eql(u8, s.name, name)) break;
            } else return .{ .model_output = try tool_search.renderServerNotFound(alloc) };
        }

        for (servers) |s| if (searched(request, s)) c.runtime.prepare(s.name) catch {};
        for (servers) |s| if (searched(request, s)) try c.refresh(s.name, cancel);
        if (try c.renderUnavailable(alloc, request)) |output| return .{ .model_output = output };

        var scratch: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch.deinit();
        var candidates: std.ArrayList(tool_search.Candidate) = .empty;
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (c.servers, c.lists, 0..) |s, l, i| {
            if (!searched(request, s) or !l.offersTools()) continue;
            for (l.tools) |*tool| {
                if (!c.allowsLocked(access, i, tool.prefixed_name)) continue;
                if (!try tool_search.searchable(scratch.allocator(), permission_rules, s.name, tool)) continue;
                try candidates.append(scratch.allocator(), .{ .server_name = s.name, .instructions = try c.runtime.instructions(scratch.allocator(), s.name), .tool = tool, .binding = c.bindingLocked(i, tool.*) });
            }
        }

        const open = request.server == null;
        var matched: std.ArrayList(usize) = .empty;
        defer matched.deinit(alloc);
        var result = try tool_search.rank(alloc, candidates.items, request, limits, if (open) &matched else null);
        if (open and matched.items.len == 0) result.model_output = try c.withUnavailableLocked(alloc, result.model_output);
        return result;
    }

    fn withUnavailableLocked(c: *Catalog, alloc: Allocator, page: []u8) ![]u8 {
        var reasons: std.ArrayList([]const u8) = .empty;
        defer {
            for (reasons.items) |reason| alloc.free(reason);
            reasons.deinit(alloc);
        }
        for (c.servers, c.lists) |s, l| {
            try reasons.ensureUnusedCapacity(alloc, 1);
            reasons.appendAssumeCapacity(try c.unavailableText(alloc, s, l) orelse continue);
        }
        if (reasons.items.len == 0) return page;
        return tool_search.withUnavailable(alloc, page, reasons.items);
    }

    pub fn toolSchema(
        c: *Catalog,
        alloc: Allocator,
        name: []const u8,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: Access,
        cancel: Cancel,
    ) !?tool_mcp_runtime.ToolSchemaResult {
        if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
        if (!c.mayAllow(access)) return null;
        try c.ensure(name, cancel);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const found = c.findLocked(name) orelse return c.whyUnavailableLocked(alloc, name);
        if (!c.allowsLocked(access, found.server, name)) return null;
        if (permissions.rulesDenyAllTargetsForPermission(permission_rules, name)) return null;
        const instructions = try c.runtime.instructions(alloc, c.servers[found.server].name);
        defer if (instructions) |text| alloc.free(text);
        var projection = try selected_schema.project(alloc, found.tool.*, instructions, limits);
        if (projection == .selected) projection.selected.mcp_binding = c.bindingLocked(found.server, found.tool.*);
        return projection;
    }

    pub fn snapshotAlwaysLoadedTools(
        c: *Catalog,
        alloc: Allocator,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: Access,
        cancel: Cancel,
    ) !selected_schema.AlwaysLoadedTools {
        const servers = c.currentServers();
        for (servers) |s| if (s.always_loaded) c.runtime.prepare(s.name) catch {};
        for (servers) |s| if (s.always_loaded) try c.refresh(s.name, cancel);
        var loaded: selected_schema.AlwaysLoaded = .init(limits);
        errdefer loaded.deinit(alloc);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (c.servers, c.lists, 0..) |s, l, i| {
            if (!s.always_loaded or !l.offersTools()) continue;
            const instructions = try c.runtime.instructions(alloc, s.name);
            defer if (instructions) |text| alloc.free(text);
            for (l.tools) |*tool| {
                if (permissions.rulesDenyAllTargetsForPermission(permission_rules, tool.prefixed_name)) continue;
                if (!c.allowsLocked(access, i, tool.prefixed_name)) continue;
                try loaded.add(alloc, tool.*, instructions, c.bindingLocked(i, tool.*), limits);
            }
        }
        return loaded.finish(alloc);
    }

    pub fn snapshotToolDefinition(
        c: *Catalog,
        alloc: Allocator,
        name: []const u8,
        known_binding: Binding,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: Access,
    ) !tool_mcp_runtime.DefinitionSnapshot {
        if (!c.mayAllow(access)) return .unavailable;
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const found = c.findLocked(name) orelse return .unavailable;
        if (!c.allowsLocked(access, found.server, name)) return .unavailable;
        if (permissions.rulesDenyAllTargetsForPermission(permission_rules, name)) return .unavailable;
        const current = c.bindingLocked(found.server, found.tool.*);
        if (std.meta.eql(known_binding, current)) return .current;
        const instructions = try c.runtime.instructions(alloc, c.servers[found.server].name);
        defer if (instructions) |text| alloc.free(text);
        var projection = try selected_schema.project(alloc, found.tool.*, instructions, limits);
        if (projection == .rejected) {
            projection.deinit(alloc);
            return .unavailable;
        }
        if (projection.selected.notice) |notice| alloc.free(notice);
        errdefer alloc.free(projection.selected.model_output);
        return .{ .updated = .{ .name = try alloc.dupe(u8, name), .schema_json = projection.selected.model_output, .mcp_binding = current } };
    }

    pub fn listTools(
        c: *Catalog,
        alloc: Allocator,
        permission_rules: types.PermissionRuleSet,
        access: Access,
        cancel: Cancel,
    ) ![]const tool_mcp_runtime.ListedTool {
        if (!c.mayAllow(access)) return &.{};
        const servers = c.currentServers();
        for (servers) |s| c.runtime.prepare(s.name) catch {};
        for (servers) |s| try c.refresh(s.name, cancel);
        var listed: std.ArrayList(tool_mcp_runtime.ListedTool) = .empty;
        errdefer listed.deinit(alloc);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (c.lists, 0..) |l, i| {
            if (!l.offersTools()) continue;
            for (l.tools) |tool| {
                if (permissions.rulesDenyAllTargetsForPermission(permission_rules, tool.prefixed_name)) continue;
                if (!c.allowsLocked(access, i, tool.prefixed_name)) continue;
                try listed.append(alloc, .{
                    .name = try alloc.dupe(u8, tool.prefixed_name),
                    .description = try alloc.dupe(u8, tool.description),
                    .input_schema_json = try alloc.dupe(u8, tool.input_schema_json),
                });
            }
        }
        return listed.toOwnedSlice(alloc);
    }

    pub fn snapshotToolNames(c: *Catalog, alloc: Allocator, permission_rules: types.PermissionRuleSet) ![][]u8 {
        var names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (names.items) |n| alloc.free(n);
            names.deinit(alloc);
        }
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (c.lists) |l| {
            if (!l.offersTools()) continue;
            for (l.tools) |tool| {
                if (permissions.rulesDenyAllTargetsForPermission(permission_rules, tool.prefixed_name)) continue;
                const name = try alloc.dupe(u8, tool.prefixed_name);
                names.append(alloc, name) catch |err| {
                    alloc.free(name);
                    return err;
                };
            }
        }
        return names.toOwnedSlice(alloc);
    }

    pub fn snapshotAccessView(
        c: *Catalog,
        alloc: Allocator,
        owner_id: []const u8,
        parent_id: []const u8,
        permission_rules: types.PermissionRuleSet,
    ) !access_policy.View {
        var servers: std.ArrayList(access_policy.ServerIdentity) = .empty;
        var tools: std.ArrayList(access_policy.ToolIdentity) = .empty;
        errdefer {
            for (servers.items) |*s| s.deinit(alloc);
            servers.deinit(alloc);
            for (tools.items) |*t| t.deinit(alloc);
            tools.deinit(alloc);
        }
        var scratch: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch.deinit();
        const statuses = try c.runtime.statuses(scratch.allocator());
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (c.servers, c.lists) |s, l| {
            const status = statusOf(statuses, s.name) orelse continue;
            switch (status.state) {
                .waiting_for_approval, .rejected, .disabled, .unsupported, .missing_env, .invalid_env => continue,
                else => {},
            }
            try servers.ensureUnusedCapacity(alloc, 1);
            servers.appendAssumeCapacity(.{
                .name = try alloc.dupe(u8, s.name),
                .source = s.source,
                .scope = s.scope,
                .connection_generation = l.generation,
                .catalog_generation = l.generation,
                .auth_generation = 0,
            });
            if (!l.offersTools()) continue;
            for (l.tools) |tool| {
                if (permissions.rulesDenyAllTargetsForPermission(permission_rules, tool.prefixed_name)) continue;
                try tools.ensureUnusedCapacity(alloc, 1);
                const name = try alloc.dupe(u8, tool.prefixed_name);
                errdefer alloc.free(name);
                tools.appendAssumeCapacity(.{ .name = name, .server_name = try alloc.dupe(u8, s.name) });
            }
        }
        const owner = try alloc.dupe(u8, owner_id);
        errdefer alloc.free(owner);
        const parent = try alloc.dupe(u8, parent_id);
        errdefer alloc.free(parent);
        const server_slice = try servers.toOwnedSlice(alloc);
        errdefer {
            for (server_slice) |*s| s.deinit(alloc);
            alloc.free(server_slice);
        }
        return .{
            .runtime_generation = c.currentGeneration(),
            .owner_id = owner,
            .parent_id = parent,
            .servers = server_slice,
            .tools = try tools.toOwnedSlice(alloc),
        };
    }

    pub fn modelSnapshot(c: *Catalog, alloc: Allocator) !model_catalog.Snapshot {
        var scratch: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch.deinit();
        const statuses = try c.runtime.statuses(scratch.allocator());
        var out: std.ArrayList(model_catalog.ServerSummary) = .empty;
        errdefer {
            for (out.items) |s| alloc.free(s.name);
            out.deinit(alloc);
        }
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (c.servers, c.lists) |server, l| {
            const s = statusOf(statuses, server.name) orelse continue;
            const availability: model_catalog.Availability = switch (s.state) {
                .waiting_for_approval, .rejected, .removed => continue,
                .disabled => .disabled,
                .unsupported, .missing_env, .invalid_env => .unavailable,
                .idle => if (l.state == .loaded) .ready else .available_on_demand,
                .connecting, .retrying => .discovering,
                .ready => .ready,
                .failed => .failed,
            };
            try out.ensureUnusedCapacity(alloc, 1);
            out.appendAssumeCapacity(.{
                .name = try alloc.dupe(u8, s.name),
                .availability = if (s.needs_login) .authentication_required else availability,
                .tool_count = if (l.state == .loaded) l.tools.len else null,
            });
        }
        return .{ .servers = try out.toOwnedSlice(alloc) };
    }

    fn searched(request: tool_mcp_runtime.SearchRequest, s: config.Server) bool {
        if (s.held != null) return false;
        const name = request.server orelse return true;
        return std.mem.eql(u8, s.name, name);
    }

    fn ensure(c: *Catalog, name: []const u8, cancel: Cancel) !void {
        if (c.known(name)) return;
        try c.load(name, cancel);
    }

    fn ensureCurrent(c: *Catalog, name: []const u8, cancel: Cancel) !void {
        if (c.upToDate(name)) return;
        try c.load(name, cancel);
    }

    fn load(c: *Catalog, name: []const u8, cancel: Cancel) !void {
        for (c.currentServers()) |s| {
            if (s.held != null or !tool_names.matchesServer(name, s.name)) continue;
            try c.refresh(s.name, cancel);
            if (c.known(name)) return;
        }
    }

    fn known(c: *Catalog, name: []const u8) bool {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        return c.findLocked(name) != null;
    }

    fn upToDate(c: *Catalog, name: []const u8) bool {
        const server, const epoch = found: {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            const found = c.findLocked(name) orelse return false;
            break :found .{ c.servers[found.server].name, c.lists[found.server].epoch };
        };
        return epoch == c.runtime.toolsEpoch(server);
    }

    fn mayAllow(c: *const Catalog, access: Access) bool {
        return switch (access) {
            .unrestricted, .servers => true,
            .disabled => false,
            .scoped => |scope| scope.captured.runtime_generation == c.currentGeneration(),
        };
    }

    fn allowsLocked(c: *const Catalog, access: Access, server: usize, name: []const u8) bool {
        if (!c.mayAllow(access)) return false;
        return switch (access) {
            .scoped => |scope| scope.captured.tool(name) != null or
                scope.captured.server(c.servers[server].name) != null,
            .servers => |filter| filter.allows(c.servers[server].name),
            else => true,
        };
    }

    pub fn toolIdentity(c: *Catalog, alloc: Allocator, name: []const u8) Allocator.Error!?catalog_state.ToolIdentity {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const found = c.findLocked(name) orelse return null;
        const server = try alloc.dupe(u8, c.servers[found.server].name);
        errdefer alloc.free(server);
        const tool = try alloc.dupe(u8, found.tool.original_name);
        errdefer alloc.free(tool);
        return .{ .server = server, .tool = tool, .title = try catalog_state.displayTitle(alloc, found.tool.*) };
    }

    fn allows(c: *Catalog, access: Access, name: []const u8) bool {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const found = c.findLocked(name) orelse return false;
        return c.allowsLocked(access, found.server, name);
    }

    fn findLocked(c: *const Catalog, name: []const u8) ?Found {
        for (c.lists, 0..) |l, i| {
            if (!l.offersTools()) continue;
            for (l.tools) |*tool| if (std.mem.eql(u8, tool.prefixed_name, name)) return .{ .server = i, .tool = tool };
        }
        return null;
    }

    fn bindingLocked(c: *const Catalog, server: usize, tool: McpTool) Binding {
        const generation = c.lists[server].generation;
        return .{
            .runtime_generation = c.currentGeneration(),
            .connection_generation = generation,
            .catalog_generation = generation,
            .auth_generation = 0,
            .definition_digest = catalog_state.definitionDigest(tool, null),
        };
    }

    fn refresh(c: *Catalog, name: []const u8, cancel: Cancel) !void {
        const server, const token = found: {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            const i = c.indexLocked(name) orelse return;
            break :found .{ c.servers[i], c.lists[i].token };
        };
        if (server.held != null) return;
        var scratch: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch.deinit();

        const epoch = c.runtime.toolsEpoch(server.name);
        const result = try c.runtime.tools(scratch.allocator(), server.name, cancel);
        switch (result) {
            .tools => |listed| {
                var arena: std.heap.ArenaAllocator = .init(c.gpa);
                errdefer arena.deinit();
                const tools = try c.build(arena.allocator(), server.name, listed);
                const digest = catalog_state.digestTools(tools);
                c.mutex.lockUncancelable(c.io);
                defer c.mutex.unlock(c.io);
                const l = c.listLocked(server.name, token) orelse {
                    arena.deinit();
                    return;
                };
                c.installLocked(l, arena, tools, digest, epoch);
                c.setStateLocked(l, .loaded, null);
            },
            .needs_login => try c.offerAuthenticate(server, token, epoch),
            .failed => |why| {
                c.mutex.lockUncancelable(c.io);
                defer c.mutex.unlock(c.io);
                c.setStateLocked(c.listLocked(server.name, token) orelse return, .failed, why);
            },
            .unknown_server => {},
        }
    }

    fn installLocked(c: *Catalog, l: *List, arena: std.heap.ArenaAllocator, tools: []McpTool, digest: [32]u8, epoch: u64) void {
        if (l.digest == null or !std.mem.eql(u8, &l.digest.?, &digest)) l.generation = c.serial();
        if (l.arena) |*old| old.deinit();
        l.arena = arena;
        l.tools = tools;
        l.digest = digest;
        l.epoch = epoch;
    }

    fn offerAuthenticate(c: *Catalog, server: config.Server, token: u64, epoch: u64) Allocator.Error!void {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        errdefer arena.deinit();
        const tools: []McpTool = if (signsInByTool(server)) try c.authenticateTools(arena.allocator(), server.name) else &.{};
        const digest = catalog_state.digestTools(tools);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const l = c.listLocked(server.name, token) orelse {
            arena.deinit();
            return;
        };
        c.installLocked(l, arena, tools, digest, epoch);
        c.setStateLocked(l, .needs_login, null);
    }

    fn signsInByTool(server: config.Server) bool {
        return server.source != .acp and server.transport == .http and server.held == null and !server.static_credentials;
    }

    fn authenticateToolName(c: *Catalog, a: Allocator, server_name: []const u8) Allocator.Error!?[]u8 {
        return c.names.name(a, c.builtins, server_name, authenticate_tool) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.McpToolNameLimitExceeded => {
                debug_trace.logf("mcp", "MCP authenticate tool left out server={s} err={s}", .{ server_name, @errorName(err) });
                return null;
            },
        };
    }

    fn authenticateTools(c: *Catalog, a: Allocator, server_name: []const u8) Allocator.Error![]McpTool {
        const prefixed = try c.authenticateToolName(a, server_name) orelse return &.{};
        const tools = try a.alloc(McpTool, 1);
        tools[0] = .{
            .original_name = authenticate_tool,
            .prefixed_name = prefixed,
            .description = try authenticateDescription(a, server_name),
            .input_schema_json = try a.dupe(u8, authenticate_input_schema),
            .tags = try tool_names.tagsFor(a, server_name, authenticate_tool),
        };
        return tools;
    }

    fn authenticate(
        c: *Catalog,
        arena: Allocator,
        server: []const u8,
        name: []const u8,
        max_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
    ) !?tool_mcp_runtime.CallResult {
        const open_browser = @import("verbs.zig").canOpenBrowser();
        const outcome = c.runtime.authenticate(arena, server, open_browser, options.cancel_flag, options.progress) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Cancelled => return error.Cancelled,
            else => return try authenticateResult(arena, name, try authenticateFailure(arena, server, signInRefusal(err), null), .tool_failure, max_bytes),
        };
        const already = switch (outcome) {
            .unknown_server => return null,
            .failed => |failed| return try authenticateResult(arena, name, try authenticateFailure(arena, server, failed.reason, failed.url), .tool_failure, max_bytes),
            .signed_in => false,
            .already_signed_in => true,
        };
        try c.refresh(server, options.cancel_flag);
        if (try c.reconnectFailure(arena, server)) |why| {
            return try authenticateResult(arena, name, try authenticateFailure(arena, server, why, null), .tool_failure, max_bytes);
        }
        var result = try authenticateResult(arena, name, try authenticateSuccess(arena, server, already), .success, max_bytes);
        errdefer result.deinit(arena);
        result.replaced_by = try c.topLevelToolNames(arena, server);
        return result;
    }

    fn topLevelToolNames(c: *Catalog, alloc: Allocator, server: []const u8) Allocator.Error![]const []const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |n| alloc.free(n);
            names.deinit(alloc);
        }
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const i = c.indexLocked(server) orelse return &.{};
        if (!c.servers[i].always_loaded or c.lists[i].state != .loaded) return &.{};
        try names.ensureTotalCapacity(alloc, c.lists[i].tools.len);
        for (c.lists[i].tools) |tool| names.appendAssumeCapacity(try alloc.dupe(u8, tool.prefixed_name));
        return names.toOwnedSlice(alloc);
    }

    fn reconnectFailure(c: *Catalog, arena: Allocator, server: []const u8) Allocator.Error!?[]const u8 {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const l = c.lists[c.indexLocked(server) orelse return "the MCP config changed, and the server is gone"];
        return switch (l.state) {
            .loaded => null,
            .needs_login => "the server still asks for a login after the sign-in",
            .failed => try arena.dupe(u8, l.failure orelse "the server did not start"),
            .unknown => "the server did not answer after the sign-in",
        };
    }

    fn setStateLocked(c: *Catalog, l: *List, state: @FieldType(List, "state"), failure: ?[]const u8) void {
        if (l.failure) |old| c.gpa.free(old);
        l.failure = if (failure) |why| c.gpa.dupe(u8, why) catch null else null;
        l.state = state;
    }

    fn build(c: *Catalog, a: Allocator, server_name: []const u8, listed: []const runtime_mod.Tool) Allocator.Error![]McpTool {
        var out: std.ArrayList(McpTool) = .empty;
        for (listed) |item| {
            const parsed = tools_feature.parseToolJson(a, item.raw, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    debug_trace.logf("mcp", "MCP tool left out server={s} tool={s} err={s}", .{ server_name, item.name, @errorName(err) });
                    continue;
                },
            };
            const prefixed = c.names.name(a, c.builtins, server_name, parsed.name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.McpToolNameLimitExceeded => {
                    debug_trace.logf("mcp", "MCP tool left out server={s} tool={s} err={s}", .{ server_name, item.name, @errorName(err) });
                    continue;
                },
            };
            try out.append(a, .{
                .original_name = parsed.name,
                .prefixed_name = prefixed,
                .title = parsed.title,
                .description = if (parsed.description.len > 0) parsed.description else try a.dupe(u8, "MCP tool"),
                .input_schema_json = parsed.input_schema_json,
                .output_schema_json = parsed.output_schema_json,
                .icons_json = parsed.icons_json,
                .annotations_json = parsed.annotations_json,
                .metadata_json = parsed.metadata_json,
                .tags = try tool_names.tagsFor(a, server_name, parsed.name),
            });
        }
        return out.items;
    }

    fn unavailableText(c: *Catalog, alloc: Allocator, s: config.Server, l: List) !?[]u8 {
        return switch (l.state) {
            .needs_login => if (l.offersTools())
                try authenticateFirstText(alloc, s.name, l.tools[0].prefixed_name)
            else
                try needsLoginText(alloc, s.name, signIn(c.runtime.options.slash_commands, s.source)),
            .failed => try alloc.print("MCP server '{s}' is unavailable: {s}", .{ s.name, l.failure orelse "it did not start" }),
            else => if (s.held == .missing_env)
                try alloc.print("MCP server '{s}' needs {s} set before fx starts.", .{ s.name, s.missing orelse "a variable" })
            else if (s.held == .invalid_env)
                try alloc.print("MCP server '{s}' can't use {s}: its value holds a line break or another character a header can't carry. Fix it, then restart fx.", .{ s.name, s.missing orelse "a variable" })
            else
                null,
        };
    }

    fn whyUnavailableLocked(c: *Catalog, alloc: Allocator, name: []const u8) !?tool_mcp_runtime.ToolSchemaResult {
        for (c.servers, c.lists) |s, l| {
            if (!tool_names.matchesServer(name, s.name)) continue;
            const text = try c.unavailableText(alloc, s, l) orelse continue;
            return .{ .rejected = .{ .model_output = text } };
        }
        return null;
    }

    fn renderUnavailable(c: *Catalog, alloc: Allocator, request: tool_mcp_runtime.SearchRequest) !?[]u8 {
        const named = request.server orelse request.query.raw;
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (c.servers, c.lists) |s, l| {
            if (!tool_search.queryContainsCompleteIdentity(named, s.name)) continue;
            if (l.state == .needs_login and !l.offersTools()) {
                const step = try signInStep(alloc, s.name, signIn(c.runtime.options.slash_commands, s.source));
                defer alloc.free(step);
                step[0] = std.ascii.toUpper(step[0]);
                const guidance = try alloc.print("{s}, then search again.", .{step});
                defer alloc.free(guidance);
                return try tool_search.writeAuthenticationRequired(alloc, s.name, .{ .oauth = guidance });
            }
            if (s.held == .missing_env) {
                return try tool_search.writeAuthenticationRequired(alloc, s.name, .{ .bearer_environment = s.missing orelse "" });
            }
        }
        const name = request.server orelse return null;
        for (c.servers, c.lists) |s, l| {
            if (!std.mem.eql(u8, s.name, name) or l.state != .failed) continue;
            return try tool_search.writeServerFailure(alloc, s.name, l.failure orelse "the server is unavailable");
        }
        return null;
    }
};

const question_timeout_ms: i64 = 10 * 60 * 1000;

const Asking = struct {
    responder: tool_mcp_runtime.InputResponder,
    tool: []const u8,
    cancel: ?*std.atomic.Value(bool),
    io: std.Io,
    origin: ?tool_mcp_runtime.InputOrigin = null,

    fn finish(self: *const Asking, alloc: Allocator, outcome: tool_mcp_runtime.ContinuationTerminal) void {
        if (self.origin) |origin| self.responder.finish(alloc, origin, outcome);
    }

    fn ask(context: *anyopaque, alloc: Allocator, question: runtime_mod.Question) anyerror!?[]u8 {
        const self: *Asking = @ptrCast(@alignCast(context));
        const origin: tool_mcp_runtime.InputOrigin = .{
            .wire = wireFor(question.version),
            .server_name = question.server,
            .operation = .{ .tools_call = self.tool },
            .connection_generation = 0,
            .client_generation = 0,
            .catalog_generation = 0,
            .request_generation = 0,
            .auth_generation = 0,
            .deadline_ms = std.Io.Clock.awake.now(self.io).toMilliseconds() + question_timeout_ms,
            .lifecycle_cancel_flag = self.cancel,
        };
        self.origin = origin;
        const signal = question.url_wait orelse {
            const answer = try self.responder.callback(self.responder.context, alloc, origin, .{ .input_requests_json = question.input_requests_json });
            return @constCast(answer);
        };

        if (!self.responder.legacy_url_manual_completion) return self.waitForUrls(signal, origin.deadline_ms);
        const answer = try self.responder.callback(self.responder.context, alloc, origin, .{
            .input_requests_json = question.input_requests_json,
            .legacy_retry_without_responses = true,
            .legacy_url_phase = .await_completion,
            .legacy_url_completion_signal = signal,
        });
        return @constCast(answer);
    }

    fn waitForUrls(self: *const Asking, signal: *const tool_mcp_runtime.LegacyUrlCompletionSignal, deadline_ms: i64) ?[]u8 {
        while (signal.status.load(.acquire) == .pending) {
            if (self.cancel) |flag| if (flag.load(.acquire)) break;
            if (std.Io.Clock.awake.now(self.io).toMilliseconds() >= deadline_ms) break;
            std.Io.sleep(self.io, .fromMilliseconds(50), .awake) catch {};
        }
        return null;
    }

    fn wireFor(version: ?[]const u8) elicitation.Wire {
        const v = version orelse return .modern_mcp;
        if (std.mem.eql(u8, v, "2025-06-18") or std.mem.eql(u8, v, "2025-03-26")) return .legacy_mcp_2025_06;
        if (std.mem.startsWith(u8, v, "2025-")) return .legacy_mcp_2025_11;
        return .modern_mcp;
    }
};

fn statusOf(statuses: []const runtime_mod.Status, name: []const u8) ?runtime_mod.Status {
    for (statuses) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

fn missingStructuredResponse(arena: Allocator, tool: []const u8) ![]u8 {
    const message = try std.fmt.allocPrint(arena, "Tool {s} has an output schema but did not return structured content", .{tool});
    const quoted = try std.json.Stringify.valueAlloc(arena, message, .{});
    return try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{{\"code\":-32600,\"message\":{s}}}}}", .{quoted});
}

fn render(arena: Allocator, server: []const u8, name: []const u8, tool: []const u8, answer: runtime_mod.CallResult, max_bytes: usize, how: SignIn, output_schema: bool, sign_in_tool: ?[]const u8) !?tool_mcp_runtime.CallResult {
    const response = switch (answer) {
        .result => |r| if (r.structured) |structured|
            try arena.print("{{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{{\"content\":{s},\"structuredContent\":{s},\"isError\":{s}}}}}", .{ r.content, structured, if (r.is_error) "true" else "false" })
        else if (output_schema and !r.is_error)
            try missingStructuredResponse(arena, tool)
        else
            try arena.print("{{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{{\"content\":{s},\"isError\":{s}}}}}", .{ r.content, if (r.is_error) "true" else "false" }),
        .failure => |f| try arena.print("{{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{{\"code\":{d},\"message\":{s}}}}}", .{ f.code, f.message }),
        .ended => |e| return try ended(arena, server, name, e, max_bytes, how, sign_in_tool),
        .unknown_server => return null,
    };
    return try tool_result.extract(arena, .{
        .server_name = server,
        .tool_name = name,
        .response = response,
        .max_tool_result_bytes = max_bytes,
        .protocol = .modern,
    });
}

fn ended(arena: Allocator, server: []const u8, name: []const u8, e: @FieldType(runtime_mod.CallResult, "ended"), max_bytes: usize, how: SignIn, sign_in_tool: ?[]const u8) !tool_mcp_runtime.CallResult {
    if (e.outcome == .cancelled and !e.timed_out) return error.Cancelled;
    const why = switch (e.outcome) {
        .needs_auth => return .{
            .model_output = try tool_result_limits.prepareModelOutput(
                arena,
                name,
                if (sign_in_tool) |authenticate_name| try unauthorizedCallText(arena, server, authenticate_name) else try needsLoginText(arena, server, how),
                max_bytes,
            ),
            .status = .tool_failure,
        },
        .lost => "the server went away",
        .auth_unavailable => "its login couldn't be renewed because the sign-in server didn't answer. The tool didn't run; try again shortly",
        .transport_failed, .http_failure => "the connection failed",
        .malformed => "the server's answer was malformed",
        .rounds_exceeded => "the server asked for input too many times",
        .unsupported_input => "the server asked for input fx can't give",
        .denied => "fx's permission refused it",
        else => @tagName(e.outcome),
    };

    const text = if (e.timed_out) try arena.print(
        "fx stopped waiting for MCP server '{s}': it did not answer within its operation timeout.{s}{s}",
        .{
            server,
            if (e.maybe_ran) " The tool may have run." else "",
            if (how == .editor) "" else " Raise toolTimeoutMs for this server in its MCP config if it needs longer.",
        },
    ) else try arena.print("MCP server '{s}' ended the call: {s}{s}.", .{
        server,
        e.why orelse why,
        if (e.maybe_ran) ". The tool may have run" else "",
    });
    return .{ .model_output = try tool_result_limits.prepareModelOutput(arena, name, text, max_bytes), .status = .protocol_failure };
}

fn removedServerNotice(alloc: Allocator, qualified_tool: []const u8) ![]u8 {
    return alloc.print("MCP server for tool \"{s}\" has been removed (plugin uninstalled or config deleted). Do not call this tool again.", .{qualified_tool});
}

test "a removed server's tool is refused in Kimi's words" {
    const text = try removedServerNotice(testing.allocator, "mcp__docs__search");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("MCP server for tool \"mcp__docs__search\" has been removed (plugin uninstalled or config deleted). Do not call this tool again.", text);
}

fn needsLoginText(alloc: Allocator, server: []const u8, how: SignIn) ![]u8 {
    const step = try signInStep(alloc, server, how);
    defer alloc.free(step);
    return alloc.print("MCP server '{s}' needs a login. Ask the user to {s}, then try again.", .{ server, step });
}

const authenticate_tool = "authenticate";
const authenticate_input_schema = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}";

fn authenticateDescription(alloc: Allocator, server: []const u8) Allocator.Error![]u8 {
    return alloc.print(
        \\Authenticate with MCP server "{s}" via OAuth.
        \\
        \\This server requires an OAuth login that has not yet been completed. Calling this tool starts the authorization flow:
        \\
        \\  1. The tool prints an authorization URL.
        \\  2. **You must show that URL to the user verbatim** and ask them to open it
        \\     in a browser, sign in, and approve the client.
        \\  3. The tool blocks (up to 15 minutes) until the browser redirects back to
        \\     the local callback listener.
        \\  4. On success, the client reconnects the MCP server and the real tools
        \\     replace this synthetic tool.
        \\
        \\Take no arguments. Treat the URL as sensitive — do not modify it or strip
        \\query parameters.
    , .{server});
}

fn authenticateSuccess(alloc: Allocator, server: []const u8, already_signed_in: bool) Allocator.Error![]u8 {
    if (already_signed_in) return alloc.print("MCP server \"{s}\" already had valid OAuth credentials. Reconnected; real tools are available now.", .{server});
    return alloc.print("MCP server \"{s}\" authenticated successfully. The real MCP tools have replaced this synthetic authenticate tool.", .{server});
}

fn authenticateFailure(alloc: Allocator, server: []const u8, reason: []const u8, authorization_url: ?[]const u8) Allocator.Error![]u8 {
    const url = authorization_url orelse return alloc.print("OAuth flow for MCP server \"{s}\" did not complete: {s}", .{ server, reason });
    return alloc.print(
        "OAuth flow for MCP server \"{s}\" did not complete: {s}\n\nAuthorization URL (still valid if the listener has not timed out): {s}",
        .{ server, reason, url },
    );
}

fn authenticateResult(arena: Allocator, name: []const u8, text: []const u8, status: tool_mcp_runtime.CallStatus, max_bytes: usize) !tool_mcp_runtime.CallResult {
    return .{ .model_output = try tool_result_limits.prepareModelOutput(arena, name, text, max_bytes), .status = status };
}

fn signInRefusal(err: runtime_mod.Error) []const u8 {
    return switch (err) {
        error.Held => "the server is held back by its config",
        error.NotHttp => "only HTTP servers sign in with OAuth",
        error.CredentialStoreUnreadable => "fx can't read its saved MCP logins",
        error.CallbackPortInUse => "the callback port in its config is in use",
        error.Stopped => "fx stopped the MCP servers",
        else => "the sign-in could not start",
    };
}

fn unauthorizedCallText(alloc: Allocator, server: []const u8, authenticate_name: []const u8) Allocator.Error![]u8 {
    return alloc.print(
        "MCP server \"{s}\" rejected the call with 401 Unauthorized and is now marked needs-auth. Call the {s} tool to complete the OAuth login, then retry the original call.",
        .{ server, authenticate_name },
    );
}

fn authenticateFirstText(alloc: Allocator, server: []const u8, authenticate_name: []const u8) Allocator.Error![]u8 {
    return alloc.print("MCP server '{s}' needs a login. Call the {s} tool to complete the OAuth login, then try again.", .{ server, authenticate_name });
}

const SignIn = enum { shell, terminal, editor };

fn signIn(slash_commands: bool, source: mcp_contract.ConfigSource) SignIn {
    if (source == .acp) return .editor;
    return if (slash_commands) .shell else .terminal;
}

fn signInStep(alloc: Allocator, server: []const u8, how: SignIn) ![]u8 {
    return switch (how) {
        .shell => alloc.print("run /mcp login {s}", .{server}),
        .terminal => alloc.print("run fx mcp login {s} in a terminal", .{server}),
        .editor => alloc.print("add an Authorization header for {s} in the editor's MCP server settings", .{server}),
    };
}

fn catalog(raw: *anyopaque) *Catalog {
    return @ptrCast(@alignCast(raw));
}

fn hasToolFn(raw: *anyopaque, name: []const u8, access: Access) bool {
    return catalog(raw).hasTool(name, access);
}

fn validateToolFn(raw: *anyopaque, arena: Allocator, name: []const u8, arguments_json: []const u8, access: Access) anyerror!tool_mcp_runtime.ValidationResult {
    return catalog(raw).validateTool(arena, name, arguments_json, access);
}

fn callToolFn(raw: *anyopaque, arena: Allocator, name: []const u8, arguments_json: []const u8, max_bytes: usize, options: tool_mcp_runtime.CallOptions) anyerror!?tool_mcp_runtime.CallResult {
    return catalog(raw).callTool(arena, name, arguments_json, max_bytes, options);
}

fn listToolsFn(raw: *anyopaque, alloc: Allocator, rules: types.PermissionRuleSet, access: Access, cancel: Cancel) anyerror![]const tool_mcp_runtime.ListedTool {
    return catalog(raw).listTools(alloc, rules, access, cancel);
}

fn readResourceFn(raw: *anyopaque, alloc: Allocator, server: []const u8, op: mcp_resources.Op, access: Access, cancel: Cancel) anyerror!tool_mcp_runtime.ResourceResult {
    return catalog(raw).readResource(alloc, server, op, access, cancel);
}

fn searchToolsFn(raw: *anyopaque, alloc: Allocator, request: tool_mcp_runtime.SearchRequest, rules: types.PermissionRuleSet, limits: context_limits.Values, access: Access, cancel: Cancel) anyerror!tool_mcp_runtime.SearchResult {
    return catalog(raw).searchTools(alloc, request, rules, limits, access, cancel);
}

fn toolSchemaFn(raw: *anyopaque, alloc: Allocator, name: []const u8, rules: types.PermissionRuleSet, limits: context_limits.Values, access: Access, cancel: Cancel) anyerror!?tool_mcp_runtime.ToolSchemaResult {
    return catalog(raw).toolSchema(alloc, name, rules, limits, access, cancel);
}

fn snapshotToolFn(raw: *anyopaque, alloc: Allocator, name: []const u8, known_binding: Binding, rules: types.PermissionRuleSet, limits: context_limits.Values, access: Access) anyerror!tool_mcp_runtime.DefinitionSnapshot {
    return catalog(raw).snapshotToolDefinition(alloc, name, known_binding, rules, limits, access);
}

const testing = std.testing;
const Fixture = @import("fake_server.zig").Fixture;
const lexical_relevance = @import("../shared/lexical_relevance.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const mcp_resources = @import("../../mcp/protocol/resources.zig");

test "a subagent made before its parent's server starts may use the server's tools" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{
        .{ .name = "fake", .command = f.server },
        .{ .name = "off", .command = f.server, .enabled = false },
    };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();
    var c: Catalog = undefined;
    try c.init(testing.allocator, testing.io, &r, .{});
    defer c.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var view = try c.snapshotAccessView(testing.allocator, "child", "parent", .{});
    defer view.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), view.servers.len);
    try testing.expectEqualStrings("fake", view.servers[0].name);
    try testing.expectEqual(@as(usize, 0), view.tools.len);
    const child: Access = .{ .scoped = .{ .captured = &view, .admission_authority_generation = 0, .live = undefined } };
    try testing.expect(c.hasTool("mcp__fake__echo", child));
    try testing.expectEqual(c.currentGeneration(), (try c.validateTool(a, "mcp__fake__echo", "{}", child)).valid);
    const result = (try c.callTool(a, "mcp__fake__echo", "{}", 4096, .{ .access = child })).?;
    try testing.expectEqual(tool_mcp_runtime.CallStatus.success, result.status);

    var other = try view.clone(testing.allocator);
    defer other.deinit(testing.allocator);
    other.runtime_generation +%= 1;
    const stale: Access = .{ .scoped = .{ .captured = &other, .admission_authority_generation = 0, .live = undefined } };
    try testing.expect(!c.hasTool("mcp__fake__echo", stale));
    try testing.expectError(error.McpAccessDenied, c.callTool(a, "mcp__fake__echo", "{}", 4096, .{ .access = stale }));
}

test "an instance's server filter allows the tools of its servers and refuses the rest" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();
    var c: Catalog = undefined;
    try c.init(testing.allocator, testing.io, &r, .{});
    defer c.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Named = struct {
        fn allows(raw: *const anyopaque, server: []const u8) bool {
            const wanted: *const []const u8 = @ptrCast(@alignCast(raw));
            return std.mem.eql(u8, wanted.*, server);
        }
    };
    const fake_name: []const u8 = "fake";
    const other_name: []const u8 = "other";
    const allowed: Access = .{ .servers = .{ .context = @ptrCast(&fake_name), .allows_fn = Named.allows } };
    const refused: Access = .{ .servers = .{ .context = @ptrCast(&other_name), .allows_fn = Named.allows } };
    try testing.expect(c.hasTool("mcp__fake__echo", allowed));
    const result = (try c.callTool(a, "mcp__fake__echo", "{}", 4096, .{ .access = allowed })).?;
    try testing.expectEqual(tool_mcp_runtime.CallStatus.success, result.status);

    try testing.expect(!c.hasTool("mcp__fake__echo", refused));
    try testing.expectError(error.McpAccessDenied, c.callTool(a, "mcp__fake__echo", "{}", 4096, .{ .access = refused }));
    const query = try lexical_relevance.prepare("echo");
    const found = try c.searchTools(a, .{ .query = &query, .kind = .mcp }, .{}, .{}, refused, null);
    try testing.expectEqual(@as(usize, 0), found.selected_tools.len);
}

test "listTools names every allowed MCP tool with its input schema and lists none when access is disabled" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();
    var c: Catalog = undefined;
    try c.init(testing.allocator, testing.io, &r, .{});
    defer c.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const listed = try c.listTools(a, .{}, .unrestricted, null);
    const echo = for (listed) |tool| {
        if (std.mem.eql(u8, tool.name, "mcp__fake__echo")) break tool;
    } else return error.TestExpectedEqual;
    try testing.expect(std.mem.find(u8, echo.input_schema_json, "\"type\"") != null);
    try testing.expectEqual(@as(usize, 0), (try c.listTools(a, .{}, .disabled, null)).len);
}

test "a tool with an output schema that returns no structured content fails naming the tool" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const response = try missingStructuredResponse(arena.allocator(), "echo");
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32600,\"message\":\"Tool echo has an output schema but did not return structured content\"}}",
        response,
    );
}

test "an MCP server's tools reach the model under fx's names" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();
    var c: Catalog = undefined;
    try c.init(testing.allocator, testing.io, &r, .{});
    defer c.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect(c.hasTool("mcp__fake__echo", .unrestricted));
    try testing.expect(!c.hasTool("mcp__fake__nope", .unrestricted));
    try testing.expect(!c.hasTool("mcp__fake__echo", .disabled));
    const identity = (try c.toolIdentity(a, "mcp__fake__echo")).?;
    try testing.expectEqualStrings("fake", identity.server);
    try testing.expectEqualStrings("echo", identity.tool);
    try testing.expect((try c.toolIdentity(a, "mcp__fake__nope")) == null);

    const query = try lexical_relevance.prepare("echo");
    const found = try c.searchTools(a, .{ .query = &query, .kind = .mcp }, .{}, .{}, .unrestricted, null);
    try testing.expect(std.mem.find(u8, found.model_output, "\"name\":\"mcp__fake__echo\",\"server\":\"fake\"") != null);
    try testing.expectEqual(@as(usize, 1), found.selected_tools.len);
    const binding = found.selected_tools[0].mcp_binding.?;
    try testing.expectEqual(c.currentGeneration(), binding.runtime_generation);

    const schema = (try c.toolSchema(a, "mcp__fake__echo", .{}, .{}, .unrestricted, null)).?;
    try testing.expect(std.meta.eql(binding, schema.selected.mcp_binding.?));
    try testing.expect(std.mem.find(u8, schema.selected.model_output, "mcp__fake__echo") != null);
    try testing.expect((try c.snapshotToolDefinition(a, "mcp__fake__echo", binding, .{}, .{}, .unrestricted)) == .current);

    try testing.expectEqual(c.currentGeneration(), (try c.validateTool(a, "mcp__fake__echo", "{}", .unrestricted)).valid);
    try testing.expect((try c.validateTool(a, "mcp__fake__echo", "[", .unrestricted)) == .invalid);

    var capture: @import("../agent/runtime/observation_testing.zig").Capture = .{ .expected_call = "mcp-call" };
    var observer = capture.observer();
    const result = (try c.callTool(a, "mcp__fake__echo", "{}", 4096, .{ .expected_binding = binding, .observer = &observer, .call_id = "mcp-call" })).?;
    try testing.expectEqual(@as(usize, 1), capture.count(.mcp_start));
    try testing.expectEqual(capture.count(.mcp_start), capture.count(.mcp_end));
    try testing.expect(capture.saw_mcp_request);
    try testing.expect(!capture.invalid);
    try testing.expectEqual(tool_mcp_runtime.CallStatus.success, result.status);
    try testing.expect(std.mem.find(u8, result.model_output, "hi") != null);
    var stale = binding;
    stale.runtime_generation +%= 1;
    try testing.expectError(error.McpAdvertisedToolChanged, c.callTool(a, "mcp__fake__echo", "{}", 4096, .{ .expected_binding = stale }));
    try testing.expect((try c.callTool(a, "mcp__fake__nope", "{}", 4096, .{})) == null);

    try testing.expectEqual(@as(usize, 1), (try c.snapshotToolNames(a, .{})).len);
    var view = try c.snapshotAccessView(testing.allocator, "child", "parent", .{});
    defer view.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), view.tools.len);
    try testing.expect(Access.allowsTool(.{ .scoped = .{ .captured = &view, .admission_authority_generation = 0, .live = undefined } }, c.currentGeneration(), "mcp__fake__echo"));
    var snapshot = try c.modelSnapshot(testing.allocator);
    defer snapshot.deinit(testing.allocator);
    try testing.expectEqual(model_catalog.Availability.ready, snapshot.servers[0].availability);
    try testing.expectEqual(@as(?usize, 1), snapshot.servers[0].tool_count);
}

test "a reload keeps a kept server's list and the bindings made from it, until a server is dropped" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const fake: mcp_contract.McpServerConfig = .{ .name = "fake", .command = f.server };
    const gone: mcp_contract.McpServerConfig = .{ .name = "gone", .command = f.server };
    const late: mcp_contract.McpServerConfig = .{ .name = "late", .command = f.server };
    const changed: mcp_contract.McpServerConfig = .{ .name = "fake", .command = f.server, .args = &.{"--new"} };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &.{ fake, gone }, &f.inherited, f.options());
    defer r.deinit();
    var c: Catalog = undefined;
    try c.init(testing.allocator, testing.io, &r, .{});
    defer c.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const binding = (try c.toolSchema(a, "mcp__fake__echo", .{}, .{}, .unrestricted, null)).?.selected.mcp_binding.?;
    try testing.expect(c.hasTool("mcp__gone__echo", .unrestricted));
    const generation = c.currentGeneration();

    try c.reload(try r.reload(&.{ fake, gone, late }, &f.inherited));
    try testing.expectEqual(generation, c.currentGeneration());
    try testing.expectEqual(@as(usize, 2), (try c.snapshotToolNames(a, .{})).len);
    try testing.expect((try c.snapshotToolDefinition(a, "mcp__fake__echo", binding, .{}, .{}, .unrestricted)) == .current);
    const result = (try c.callTool(a, "mcp__fake__echo", "{}", 4096, .{ .expected_binding = binding })).?;
    try testing.expectEqual(tool_mcp_runtime.CallStatus.success, result.status);

    try c.reload(try r.reload(&.{changed}, &f.inherited));
    try testing.expect(generation != c.currentGeneration());
    try testing.expectError(error.McpAdvertisedToolChanged, c.callTool(a, "mcp__fake__echo", "{}", 4096, .{ .expected_binding = binding }));
    try testing.expect(c.hasTool("mcp__fake__echo", .unrestricted));
}

test "a server deleted mid-session keeps its tools listed and answers calls with the removal notice, and one added mid-session waits for the next session" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const fake: mcp_contract.McpServerConfig = .{ .name = "fake", .command = f.server };
    const gone: mcp_contract.McpServerConfig = .{ .name = "gone", .command = f.server };
    const late: mcp_contract.McpServerConfig = .{ .name = "late", .command = f.server };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &.{ fake, gone }, &f.inherited, f.options());
    defer r.deinit();
    var c: Catalog = undefined;
    try c.init(testing.allocator, testing.io, &r, .{});
    defer c.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const binding = (try c.toolSchema(a, "mcp__fake__echo", .{}, .{}, .unrestricted, null)).?.selected.mcp_binding.?;
    const gone_binding = (try c.toolSchema(a, "mcp__gone__echo", .{}, .{}, .unrestricted, null)).?.selected.mcp_binding.?;
    const generation = c.currentGeneration();

    try c.reload(try r.reload(&.{ fake, late }, &f.inherited));
    try testing.expectEqual(generation, c.currentGeneration());
    try testing.expectEqual(@as(usize, 2), (try c.snapshotToolNames(a, .{})).len);
    const kept = (try c.callTool(a, "mcp__fake__echo", "{}", 4096, .{ .expected_binding = binding })).?;
    try testing.expectEqual(tool_mcp_runtime.CallStatus.success, kept.status);

    const refused = (try c.callTool(a, "mcp__gone__echo", "{}", 4096, .{ .expected_binding = gone_binding })).?;
    try testing.expectEqual(tool_mcp_runtime.CallStatus.tool_failure, refused.status);
    try testing.expect(std.mem.find(u8, refused.model_output, "MCP server for tool \"mcp__gone__echo\" has been removed (plugin uninstalled or config deleted). Do not call this tool again.") != null);

    try testing.expect(!c.hasTool("mcp__late__echo", .unrestricted));
    try testing.expect((try c.callTool(a, "mcp__late__echo", "{}", 4096, .{})) == null);
    const query = try lexical_relevance.prepare("echo");
    const found = try c.searchTools(a, .{ .query = &query, .kind = .mcp }, .{}, .{}, .unrestricted, null);
    try testing.expect(std.mem.find(u8, found.model_output, "mcp__fake__echo") != null);
    try testing.expect(std.mem.find(u8, found.model_output, "mcp__gone__echo") == null);
    try testing.expect(std.mem.find(u8, found.model_output, "mcp__late__echo") == null);

    const snapshot = try c.modelSnapshot(a);
    try testing.expectEqual(@as(usize, 1), snapshot.servers.len);
    try testing.expectEqualStrings("fake", snapshot.servers[0].name);

    try c.reload(try r.reload(&.{ fake, gone }, &f.inherited));
    const back = (try c.callTool(a, "mcp__gone__echo", "{}", 4096, .{})).?;
    try testing.expectEqual(tool_mcp_runtime.CallStatus.success, back.status);
}

test "a search says why a server it names has no tools, and calls that end say how" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{
        .name = "keyed",
        .transport = .http,
        .url = "https://example.invalid/mcp",
        .bearer_token_env = @constCast("FX_MCP_HOST_TEST_UNSET"),
    }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();
    var c: Catalog = undefined;
    try c.init(testing.allocator, testing.io, &r, .{});
    defer c.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const query = try lexical_relevance.prepare("issues");
    const keyed = try c.searchTools(a, .{ .query = &query, .kind = .mcp, .server = "keyed" }, .{}, .{}, .unrestricted, null);
    try testing.expectEqualStrings(
        "{\"tools\":[],\"count\":0,\"authentication_required\":{\"server\":\"keyed\",\"interactive\":false,\"environment\":\"FX_MCP_HOST_TEST_UNSET\",\"message\":\"Set this environment variable before starting fx.\"}}",
        keyed.model_output,
    );

    const open = try c.searchTools(a, .{ .query = &query, .kind = .mcp }, .{}, .{}, .unrestricted, null);
    try testing.expect(std.mem.find(u8, open.model_output, "MCP server 'keyed' needs FX_MCP_HOST_TEST_UNSET set before fx starts.") != null);
    const missing = try c.searchTools(a, .{ .query = &query, .kind = .mcp, .server = "nope" }, .{}, .{}, .unrestricted, null);
    try testing.expect(std.mem.find(u8, missing.model_output, "\"state\":\"server_not_found\"") != null);

    const login = try ended(a, "linear", "mcp_linear_list", .{ .outcome = .needs_auth, .maybe_ran = false, .timed_out = false }, 4096, .terminal, null);
    try testing.expectEqual(tool_mcp_runtime.CallStatus.tool_failure, login.status);
    try testing.expect(std.mem.find(u8, login.model_output, "Ask the user to run fx mcp login linear in a terminal, then try again.") != null);

    const in_shell = try ended(a, "linear", "mcp_linear_list", .{ .outcome = .needs_auth, .maybe_ran = false, .timed_out = false }, 4096, .shell, null);
    try testing.expect(std.mem.find(u8, in_shell.model_output, "Ask the user to run /mcp login linear, then try again.") != null);
    try testing.expect(std.mem.find(u8, in_shell.model_output, "terminal") == null);

    try testing.expectEqual(SignIn.editor, signIn(true, .acp));
    try testing.expectEqual(SignIn.editor, signIn(false, .acp));
    try testing.expectEqual(SignIn.shell, signIn(true, .workspace));
    try testing.expectEqual(SignIn.terminal, signIn(false, .profile));
    const in_editor = try ended(a, "linear", "mcp_linear_list", .{ .outcome = .needs_auth, .maybe_ran = false, .timed_out = false }, 4096, .editor, null);
    try testing.expect(std.mem.find(u8, in_editor.model_output, "Ask the user to add an Authorization header for linear in the editor's MCP server settings, then try again.") != null);
    try testing.expect(std.mem.find(u8, in_editor.model_output, "fx mcp login") == null);
    const lost = try ended(a, "linear", "mcp_linear_list", .{ .outcome = .lost, .maybe_ran = true, .timed_out = false }, 4096, .terminal, null);
    try testing.expectEqual(tool_mcp_runtime.CallStatus.protocol_failure, lost.status);
    try testing.expect(std.mem.find(u8, lost.model_output, "the server went away. The tool may have run.") != null);
    const unrenewed = try ended(a, "slack", "mcp_slack_send", .{ .outcome = .auth_unavailable, .maybe_ran = false, .timed_out = false }, 4096, .terminal, null);
    try testing.expect(std.mem.find(u8, unrenewed.model_output, "its login couldn't be renewed because the sign-in server didn't answer. The tool didn't run; try again shortly.") != null);
    try testing.expect(std.mem.find(u8, unrenewed.model_output, "may have run") == null);
    try testing.expectError(error.Cancelled, ended(a, "linear", "mcp_linear_list", .{ .outcome = .cancelled, .maybe_ran = false, .timed_out = false }, 4096, .terminal, null));

    const slow = try ended(a, "aside", "mcp_aside_repl", .{ .outcome = .cancelled, .maybe_ran = true, .timed_out = true }, 4096, .terminal, null);
    try testing.expectEqual(tool_mcp_runtime.CallStatus.protocol_failure, slow.status);
    try testing.expect(std.mem.find(u8, slow.model_output, "fx stopped waiting for MCP server 'aside': it did not answer within its operation timeout. The tool may have run. Raise toolTimeoutMs for this server in its MCP config if it needs longer.") != null);

    const slow_in_editor = try ended(a, "aside", "mcp_aside_repl", .{ .outcome = .cancelled, .maybe_ran = false, .timed_out = true }, 4096, .editor, null);
    try testing.expect(std.mem.find(u8, slow_in_editor.model_output, "fx stopped waiting for MCP server 'aside': it did not answer within its operation timeout.") != null);
    try testing.expect(std.mem.find(u8, slow_in_editor.model_output, "toolTimeoutMs") == null);
}

test "a server that needs a login offers only its authenticate tool, described in Kimi's words" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{
        .{ .name = "web", .transport = .http, .url = "https://web.example.invalid/mcp" },
        .{ .name = "editor", .transport = .http, .url = "https://editor.example.invalid/mcp", .source = .acp, .scope = .acp_session },
        .{ .name = "events", .transport = .sse, .url = "https://events.example.invalid/sse" },
    };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();
    var c: Catalog = undefined;
    try c.init(testing.allocator, testing.io, &r, .{});
    defer c.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for (c.currentServers(), 0..) |server, i| try c.offerAuthenticate(server, c.lists[i].token, 0);

    try testing.expect(c.lists[0].offersTools());
    try testing.expect(!c.lists[1].offersTools());
    try testing.expect(!c.lists[2].offersTools());
    const names = try c.snapshotToolNames(a, .{});
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("mcp__web__authenticate", names[0]);

    const offered = c.lists[0].tools[0];
    try testing.expectEqualStrings("authenticate", offered.original_name);
    try testing.expectEqualStrings("{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}", offered.input_schema_json);
    try testing.expectEqualStrings(
        "Authenticate with MCP server \"web\" via OAuth.\n\n" ++
            "This server requires an OAuth login that has not yet been completed. Calling this tool starts the authorization flow:\n\n" ++
            "  1. The tool prints an authorization URL.\n" ++
            "  2. **You must show that URL to the user verbatim** and ask them to open it\n" ++
            "     in a browser, sign in, and approve the client.\n" ++
            "  3. The tool blocks (up to 15 minutes) until the browser redirects back to\n" ++
            "     the local callback listener.\n" ++
            "  4. On success, the client reconnects the MCP server and the real tools\n" ++
            "     replace this synthetic tool.\n\n" ++
            "Take no arguments. Treat the URL as sensitive \u{2014} do not modify it or strip\n" ++
            "query parameters.",
        offered.description,
    );

    try testing.expect(c.hasTool("mcp__web__authenticate", .unrestricted));
    try testing.expectEqual(c.currentGeneration(), (try c.validateTool(a, "mcp__web__authenticate", "{}", .unrestricted)).valid);
    const schema = (try c.toolSchema(a, "mcp__web__authenticate", .{}, .{}, .unrestricted, null)).?;
    try testing.expect(std.mem.find(u8, schema.selected.model_output, "mcp__web__authenticate") != null);

    const why = (try c.unavailableText(a, c.currentServers()[0], c.lists[0])).?;
    try testing.expectEqualStrings("MCP server 'web' needs a login. Call the mcp__web__authenticate tool to complete the OAuth login, then try again.", why);
    const editor_why = (try c.unavailableText(a, c.currentServers()[1], c.lists[1])).?;
    try testing.expectEqualStrings("MCP server 'editor' needs a login. Ask the user to add an Authorization header for editor in the editor's MCP server settings, then try again.", editor_why);
}

test "the authenticate tool reports its outcome in Kimi's words, and a 401 names the tool to call" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "MCP server \"linear\" authenticated successfully. The real MCP tools have replaced this synthetic authenticate tool.",
        try authenticateSuccess(a, "linear", false),
    );
    try testing.expectEqualStrings(
        "MCP server \"linear\" already had valid OAuth credentials. Reconnected; real tools are available now.",
        try authenticateSuccess(a, "linear", true),
    );
    try testing.expectEqualStrings(
        "OAuth flow for MCP server \"linear\" did not complete: the browser didn't come back within 15 minutes\n\n" ++
            "Authorization URL (still valid if the listener has not timed out): https://auth.example.test/authorize?state=abc&code_challenge=xyz",
        try authenticateFailure(a, "linear", "the browser didn't come back within 15 minutes", "https://auth.example.test/authorize?state=abc&code_challenge=xyz"),
    );
    try testing.expectEqualStrings(
        "OAuth flow for MCP server \"linear\" did not complete: only HTTP servers sign in with OAuth",
        try authenticateFailure(a, "linear", signInRefusal(error.NotHttp), null),
    );
    const failed = try authenticateResult(a, "mcp__linear__authenticate", "OAuth flow for MCP server \"linear\" did not complete: refused", .tool_failure, 4096);
    try testing.expectEqual(tool_mcp_runtime.CallStatus.tool_failure, failed.status);

    const unauthorized = try ended(a, "linear", "mcp__linear__list", .{ .outcome = .needs_auth, .maybe_ran = false, .timed_out = false }, 4096, .shell, "mcp__linear__authenticate");
    try testing.expectEqual(tool_mcp_runtime.CallStatus.tool_failure, unauthorized.status);
    try testing.expect(std.mem.find(
        u8,
        unauthorized.model_output,
        "MCP server \"linear\" rejected the call with 401 Unauthorized and is now marked needs-auth. Call the mcp__linear__authenticate tool to complete the OAuth login, then retry the original call.",
    ) != null);
    try testing.expect(std.mem.find(u8, unauthorized.model_output, "/mcp login") == null);
}
