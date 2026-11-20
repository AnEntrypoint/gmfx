const std = @import("std");

pub const wire = @import("protocol/wire.zig");

pub const tools = @import("protocol/tools.zig");
pub const resources = @import("protocol/resources.zig");

pub const mrtr = @import("protocol/mrtr.zig");

pub const subscriptions = @import("protocol/subscriptions.zig");
pub const elicitation = @import("protocol/elicitation.zig");

pub const auth = struct {
    pub const discovery = @import("auth/discovery.zig");
    pub const oauth = @import("auth/oauth.zig");
    pub const client = @import("auth/client.zig");
};

pub const http_headers = @import("protocol/http_headers.zig");

pub const stdio = @import("io/process.zig");

pub const http = @import("io/http.zig");

pub const server = @import("server.zig");

pub const engine = @import("engine.zig");

pub const Host = @import("host.zig").Host;

pub const trace = @import("io/trace.zig");

pub const core = struct {
    pub const request = @import("core/request.zig");
    pub const stdio_conn = @import("core/stdio_conn.zig");
    pub const era = @import("core/era.zig");
    pub const catalog = @import("core/catalog.zig");
    pub const http_modern = @import("core/http_modern.zig");
    pub const http_legacy = @import("core/http_legacy.zig");
    pub const http_sse = @import("core/http_sse.zig");
    pub const mrtr = @import("core/mrtr.zig");
    pub const auth = @import("core/auth.zig");
    pub const subscription = @import("core/subscription.zig");
    pub const elicitation = @import("core/elicitation.zig");
    pub const engine = @import("core/engine.zig");
};

test {
    _ = wire;
    _ = tools;
    _ = mrtr;
    _ = subscriptions;
    _ = elicitation;
    _ = auth.discovery;
    _ = auth.oauth;
    _ = auth.client;
    _ = http_headers;
    _ = @import("protocol/sse.zig");
    _ = trace;
    _ = stdio;
    _ = http;
    _ = server;
    _ = engine;
    _ = @import("io/lines.zig");
    _ = @import("io/bell.zig");
    _ = @import("io/budget.zig");
    _ = core.request;
    _ = core.stdio_conn;
    _ = core.era;
    _ = core.catalog;
    _ = core.http_modern;
    _ = core.http_legacy;
    _ = core.http_sse;
    _ = core.mrtr;
    _ = core.auth;
    _ = core.subscription;
    _ = core.elicitation;
    _ = core.engine;
}
