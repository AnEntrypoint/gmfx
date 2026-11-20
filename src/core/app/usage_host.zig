const std = @import("std");
const usage = @import("../../usage/usage.zig");
const client = @import("../../gateway/client.zig");
const js_host_stream_provider = @import("../../gateway/js_host_stream_provider.zig");
const stream_provider = @import("../agent/stream_provider.zig");
const host_target = @import("../hosts/target.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const oauth_session = @import("../auth/oauth_session.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;

const vercel_api_origin = "https://api.vercel.com";
const clock_file_env = "FX_TEST_USAGE_CLOCK_FILE";

pub const unset: usage.Host = .{ .fetch_fn = fetch, .now_fn = now, .io_fn = io, .home = "" };

pub fn host(home: []const u8) usage.Host {
    return .{
        .fetch_fn = fetch,
        .now_fn = now,
        .io_fn = io,
        .home = profile_paths.rootParent(home),
        .fx_dir_name = profile_paths.rootName(),
    };
}

pub fn cooperativeHost(comptime App: type, app: *App, home: []const u8) usage.Host {
    const Cooperative = struct {
        fn fetch(ctx: ?*anyopaque, alloc: Allocator, request: usage.Request, cancel: *std.atomic.Value(bool)) usage.FetchError!usage.Response {
            return send(alloc, request, cancel, .{ .ctx = ctx.?, .run = pulse });
        }

        fn pulse(ctx: *anyopaque) anyerror!void {
            const owner: *App = @ptrCast(@alignCast(ctx));
            try owner.cooperativeTransportPulse(owner.screenAgent());
            if (owner.should_exit) return error.Cancelled;
        }
    };
    return .{ .ctx = app, .fetch_fn = Cooperative.fetch, .now_fn = now, .io_fn = io, .home = home };
}

fn io(_: ?*anyopaque) std.Io {
    return io_mod.getIo();
}

pub const LabelBuffer = [160]u8;

pub fn credential(auth: *const auth_runtime.Runtime, label_buf: *LabelBuffer) ?usage.Credential {
    const current = auth.gatewayCredential() orelse {
        const selected = auth.selected_credential;
        debug_trace.logf("usage", "no gateway credential: source={s} selected={} needs_refresh={}", .{
            if (auth.credentialSource()) |source| @tagName(source) else "none",
            selected != null,
            if (selected) |c| c.needsRefreshAt(io_mod.milliTimestamp()) else false,
        });
        return null;
    };
    const mapped = fromParts(current.source, current.api_key, current.gateway_team, current.team_slug, current.account, label_buf);
    if (mapped == null) debug_trace.logf("usage", "gateway credential not usable: source={s}", .{@tagName(current.source)});
    return mapped;
}

pub fn missingReason(auth: *const auth_runtime.Runtime) usage.Unavailable {
    const source = auth.credentialSource() orelse return .no_gateway_sign_in;
    return switch (source) {
        .fx_login, .stored_key, .ai_gateway_api_key => .no_gateway_sign_in,

        .chatgpt_subscription, .grok_subscription => .refresh_needed,
        else => .unsupported_provider,
    };
}

pub fn fromCredential(c: credentials.Credential, label_buf: *LabelBuffer) ?usage.Credential {
    return fromParts(c.source, c.token, c.gatewayTeam(), c.team_slug, c.account_id, label_buf);
}

fn fromParts(
    source: credentials.Source,
    token: ?[]const u8,
    team: ?[]const u8,
    team_slug: ?[]const u8,
    account: ?[]const u8,
    label_buf: *LabelBuffer,
) ?usage.Credential {
    const bearer = token orelse return null;
    return switch (source) {
        .fx_login => .{
            .scope = .member,
            .bearer = bearer,
            .team = team,
            .subject = account orelse team orelse "",
            .label = std.mem.print(label_buf, "{s} (fx login)", .{team_slug orelse team orelse "no team"}) catch "fx login",
        },
        .stored_key, .ai_gateway_api_key => .{
            .scope = .api_key,
            .bearer = bearer,
            .team = null,
            .subject = bearer,
            .label = if (source == .ai_gateway_api_key) "API key (AI_GATEWAY_API_KEY)" else "API key (stored)",
        },
        .chatgpt_subscription => .{
            .scope = .codex,
            .bearer = bearer,
            .team = null,
            .subject = account orelse bearer,
            .account_id = account,
            .label = "codex (ChatGPT)",
        },
        .grok_subscription => .{
            .scope = .grok,
            .bearer = bearer,
            .team = null,
            .subject = account orelse bearer,
            .account_id = account,
            .label = "grok (xAI)",
        },
        else => null,
    };
}

const chatgpt_origin = "https://chatgpt.com";

fn chatgptOrigin() []const u8 {
    const override = io_mod.getenv("FX_TEST_CHATGPT_ORIGIN") orelse return chatgpt_origin;
    return if (client.isLoopbackHttpUrl(override)) override else chatgpt_origin;
}

const grok_origin = "https://cli-chat-proxy.grok.com/v1";

fn grokOrigin() []const u8 {
    const override = io_mod.getenv("FX_TEST_GROK_ORIGIN") orelse return grok_origin;
    return if (client.isLoopbackHttpUrl(override)) override else grok_origin;
}

fn vercelApiOrigin() []const u8 {
    const issuer = oauth_session.configuredIssuerUrl() catch return vercel_api_origin;
    return if (oauth_session.isLoopbackE2EIssuer(issuer)) issuer else vercel_api_origin;
}

fn fetch(
    _: ?*anyopaque,
    alloc: Allocator,
    request: usage.Request,
    cancel: *std.atomic.Value(bool),
) usage.FetchError!usage.Response {
    return send(alloc, request, cancel, null);
}

fn send(
    alloc: Allocator,
    request: usage.Request,
    cancel: *std.atomic.Value(bool),
    pulse: ?stream_provider.CooperativePulse,
) usage.FetchError!usage.Response {
    const origin = switch (request.service) {
        .gateway => client.gatewayBaseUrl(),
        .vercel_api => vercelApiOrigin(),
        .chatgpt => chatgptOrigin(),
        .grok => grokOrigin(),
    };
    const account: client.UsageAccount = if (request.account_id) |id| switch (request.service) {
        .chatgpt => .{ .chatgpt = id },
        .grok => .{ .grok = id },
        .gateway, .vercel_api => .none,
    } else .none;
    const url = try alloc.print("{s}{s}", .{ origin, request.path });
    defer alloc.free(url);
    const sent = if (comptime host_target.is_wasm)
        client.fetchUsageGetThroughHost(alloc, js_host_stream_provider.transport, request.bearer, request.team, account, url, cancel, pulse)
    else
        client.fetchUsageGet(alloc, request.bearer, request.team, account, url, cancel);
    const result = sent catch |err| switch (err) {
        error.Cancelled => return error.Cancelled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("usage", "usage fetch failed service={s} reason={s}", .{
                @tagName(request.service),
                @errorName(err),
            });
            return error.Unavailable;
        },
    };
    debug_trace.logf("usage", "usage fetch service={s} status={d}", .{
        @tagName(request.service),
        @backingInt(result.status),
    });
    return .{ .status = @backingInt(result.status), .body = result.body };
}

fn now(_: ?*anyopaque) i64 {
    if (io_mod.getenv(clock_file_env)) |path| {
        if (readClockFile(path)) |ms| return ms;
    }
    return io_mod.milliTimestamp();
}

fn readClockFile(path: []const u8) ?i64 {
    var buf: [32]u8 = undefined;
    const file_io = io_mod.getIo();
    var file = std.Io.Dir.openFileAbsolute(file_io, path, .{}) catch return null;
    defer file.close(file_io);
    const len = file.readPositionalAll(file_io, &buf, 0) catch return null;
    return std.fmt.parseInt(i64, std.mem.trim(u8, buf[0..len], " \t\r\n"), 10) catch null;
}
