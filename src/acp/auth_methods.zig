const std = @import("std");
const server = @import("server.zig");
const jsonrpc = @import("jsonrpc.zig");
const acp_types = @import("types.zig");
const chatgpt_oauth = @import("../core/auth/chatgpt_oauth.zig");
const credentials = @import("../core/auth/credentials.zig");
const grok_oauth = @import("../core/auth/grok_oauth.zig");
const login_flow = @import("../core/auth/login_flow.zig");
const secret = @import("../core/auth/secret.zig");
const config_runtime = @import("../core/config/config_runtime.zig");
const model_provider = @import("../core/config/model_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;
const ErrorCode = jsonrpc.ErrorCode;

pub fn handleAuthenticate(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid params" });
    defer parsed.deinit();
    const method_id = requestedMethodId(parsed.value) orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing methodId",
    });
    if (!knownMethodId(method_id)) return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Unknown auth method",
    });
    if (!try server.selectCredentialForProvider(state, state.provider)) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.auth_required,
            .message = missingCredentialMessage(state.provider),
        });
    }
    try state.writer.writeResponse(alloc, msg.id, "{}");
}

pub fn handleLogout(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    if (hostManagesSignIn(state)) return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_request,
        .message = "Sign-in is managed by the host",
    });
    if (!removeSavedSignIn(state, alloc)) return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.internal_error,
        .message = "Failed to remove the saved sign-in",
    });
    dropServerCredential(state);
    try state.writer.writeResponse(alloc, msg.id, "{}");
}

fn requestedMethodId(root: std.json.Value) ?[]const u8 {
    if (root != .object) return null;
    const value = root.object.get("methodId") orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn knownMethodId(method_id: []const u8) bool {
    return std.mem.eql(u8, method_id, acp_types.terminal_login_method_id);
}

fn missingCredentialMessage(provider: model_provider.ProviderId) []const u8 {
    return switch (provider) {
        .codex => credentials.missing_chatgpt_credential_message,
        .grok => credentials.missing_grok_credential_message,
        .configured => "Configured provider authentication is unavailable",
        .gateway => credentials.missing_credential_message,
    };
}

fn hostManagesSignIn(state: *const server.ServerState) bool {
    if (state.cfg.auth_mode == .host_managed) return true;
    return state.provider != .gateway and state.cfg.provider_auth_mode == .host_managed;
}

fn removeSavedSignIn(state: *server.ServerState, alloc: Allocator) bool {
    const transport = state.cfg.gateway_provider.oauth_transport;
    switch (state.provider) {
        .codex => {
            const outcome = chatgpt_oauth.logout() catch return false;
            return outcome != .deleted_not_durable;
        },
        .grok => {
            const outcome = grok_oauth.logout(alloc, transport) catch return false;
            return outcome.deletion != .deleted_not_durable;
        },
        .gateway => {
            const result = login_flow.logout(alloc, transport) catch return false;
            if (result.local_durability_failed) return false;
            clearSavedCredentialSource(state, alloc);
            return true;
        },
        .configured => return true,
    }
}

fn clearSavedCredentialSource(state: *const server.ServerState, alloc: Allocator) void {
    const home = state.cfg.home_override orelse io_mod.homeDir() orelse return;
    var preference = config_runtime.attemptUserPreferencesInHome(alloc, home, .{ .clear_credential_source = true });
    defer preference.deinit(alloc);
    switch (preference) {
        .outcome => {},
        .failure => |failure| debug_trace.logf(
            "auth",
            "ACP logout credential preference clear failed err={s}",
            .{@errorName(failure.err)},
        ),
    }
}

fn dropServerCredential(state: *server.ServerState) void {
    if (state.active_session) |*active| {
        active.api_key = &.{};
        active.credential_refresh_after_ms = null;
        active.account_id = null;
    }
    if (state.api_key.len > 0) secret.zeroAndFree(state.alloc, state.api_key);
    state.api_key = &.{};
    state.credential_refresh_after_ms = null;
    if (state.account_id) |account_id| state.alloc.free(account_id);
    state.account_id = null;
    if (state.gateway_team) |team| state.alloc.free(team);
    state.gateway_team = null;
}

test "authenticate takes only the advertised terminal login method id" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"methodId\":\"login\"}", .{});
    defer parsed.deinit();
    try std.testing.expect(knownMethodId(requestedMethodId(parsed.value).?));
    var other = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"methodId\":\"api-key\"}", .{});
    defer other.deinit();
    try std.testing.expect(!knownMethodId(requestedMethodId(other.value).?));
    var missing = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"methodId\":3}", .{});
    defer missing.deinit();
    try std.testing.expect(requestedMethodId(missing.value) == null);
    try std.testing.expectEqualStrings(credentials.missing_chatgpt_credential_message, missingCredentialMessage(.codex));
    try std.testing.expectEqualStrings(credentials.missing_credential_message, missingCredentialMessage(.gateway));
}

test "logout drops the credential the server and its active session hold" {
    const alloc = std.testing.allocator;
    var state: server.ServerState = undefined;
    state.alloc = alloc;
    state.active_session = null;
    state.api_key = try alloc.dupe(u8, "saved-token");
    state.credential_refresh_after_ms = 99;
    state.account_id = try alloc.dupe(u8, "account");
    state.gateway_team = try alloc.dupe(u8, "team");

    dropServerCredential(&state);

    try std.testing.expectEqual(@as(usize, 0), state.api_key.len);
    try std.testing.expectEqual(@as(?i64, null), state.credential_refresh_after_ms);
    try std.testing.expect(state.account_id == null);
    try std.testing.expect(state.gateway_team == null);
}
