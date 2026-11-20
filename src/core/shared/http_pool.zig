const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("debug_trace.zig");
const io_mod = @import("io.zig");
const local_address = @import("local_address.zig");

const default_ttl_ms: i64 = 30_000;
const brief_wait_limit_ms = 500;
const brief_wait_step_ms = 10;

pub const HttpPool = struct {
    client: std.http.Client,
    setup_lock: std.Io.RwLock = .init,
    ttl_ms: i64 = default_ttl_ms,
    last_activity_ms: std.atomic.Value(i64) = .init(0),
    warm_started: std.atomic.Value(bool) = .init(false),
    warm_done: std.atomic.Value(bool) = .init(false),
    open_jobs: std.atomic.Value(u32) = .init(0),
    deinitialized: bool = false,

    pub const DestroyDisposition = enum {
        destroyed,
        abandoned_warm_flight,
        abandoned_open_job,
    };

    pub fn init(alloc: std.mem.Allocator) HttpPool {
        return .{ .client = .{ .allocator = alloc, .io = io_mod.getIo() } };
    }

    pub fn deinit(self: *HttpPool) DestroyDisposition {
        if (self.deinitialized) return .destroyed;
        self.deinitialized = true;
        if (self.warm_started.load(.acquire) and !waitBriefly(self, warmFlightDone)) {
            debug_trace.logf("gateway", "pool_deinit result=abandoned_warm_flight", .{});
            return .abandoned_warm_flight;
        }
        if (!waitBriefly(self, openJobsDone)) {
            debug_trace.logf("gateway", "pool_deinit result=abandoned_open_job jobs={d}", .{self.open_jobs.load(.acquire)});
            return .abandoned_open_job;
        }
        self.client.deinit();
        return .destroyed;
    }

    fn waitBriefly(self: *const HttpPool, comptime done: fn (*const HttpPool) bool) bool {
        var waited_ms: u64 = 0;
        while (!done(self) and waited_ms < brief_wait_limit_ms) : (waited_ms += brief_wait_step_ms) {
            io_mod.sleep(brief_wait_step_ms * std.time.ns_per_ms);
        }
        return done(self);
    }

    fn warmFlightDone(self: *const HttpPool) bool {
        return self.warm_done.load(.acquire);
    }

    fn openJobsDone(self: *const HttpPool) bool {
        return self.open_jobs.load(.acquire) == 0;
    }

    pub fn beginOpenJob(self: *HttpPool) void {
        _ = self.open_jobs.fetchAdd(1, .acq_rel);
    }

    pub fn endOpenJob(self: *HttpPool) void {
        _ = self.open_jobs.fetchSub(1, .acq_rel);
    }

    pub fn noteActivity(self: *HttpPool) void {
        self.last_activity_ms.store(io_mod.milliTimestamp(), .release);
    }

    pub fn freeConnectionCount(self: *HttpPool) usize {
        const io = io_mod.getIo();
        self.client.connection_pool.mutex.lockUncancelable(io);
        defer self.client.connection_pool.mutex.unlock(io);
        return self.client.connection_pool.free_len;
    }

    fn warm(self: *HttpPool, url: []const u8) void {
        const io = io_mod.getIo();
        const uri = std.Uri.parse(url) catch return;
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return;
        if (protocol == .tls) {
            self.ensureTlsReady() catch |err| {
                debug_trace.logf("gateway", "pool_warm result=error stage=tls_init err={s}", .{@errorName(err)});
                return;
            };
        }
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = std.Io.net.HostName.fromUri(uri, &host_buf) catch return;
        const port: u16 = uri.port orelse defaultPort(protocol);
        const started = io_mod.milliTimestamp();
        const conn = conn: {
            self.setup_lock.lockSharedUncancelable(io);
            defer self.setup_lock.unlockShared(io);
            break :conn self.client.connect(host, port, protocol) catch |err| {
                debug_trace.logf("gateway", "pool_warm result=error err={s}", .{@errorName(err)});
                return;
            };
        };
        self.client.connection_pool.release(conn, io);
        self.noteActivity();
        debug_trace.logf("gateway", "pool_warm result=ok elapsed_ms={d}", .{io_mod.milliTimestamp() - started});
    }

    fn ensureTlsReady(self: *HttpPool) !void {
        const client = &self.client;
        const io = client.io;
        {
            try client.ca_bundle_lock.lockShared(io);
            defer client.ca_bundle_lock.unlockShared(io);
            if (client.now != null) return;
        }
        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(client.allocator);
        const now = std.Io.Clock.real.now(io);
        bundle.rescan(client.allocator, io, now) catch return error.CertificateBundleLoadFailure;
        try client.ca_bundle_lock.lock(io);
        defer client.ca_bundle_lock.unlock(io);
        if (client.now != null) return;
        client.now = now;
        std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
    }

    pub fn warmAsync(self: *HttpPool, url: []const u8) void {
        if (comptime builtin.is_test) return;
        if (self.warm_started.swap(true, .acq_rel)) return;
        const thread = std.Thread.spawn(.{}, warmThreadMain, .{ self, url }) catch {
            self.warm_started.store(false, .release);
            return;
        };
        thread.detach();
    }

    fn warmThreadMain(self: *HttpPool, url: []const u8) void {
        defer self.warm_done.store(true, .release);
        self.warm(url);
    }

    pub fn clientFor(self: *HttpPool, url: []const u8) *std.http.Client {
        self.drainIfStale(url);
        return &self.client;
    }

    pub fn openRequest(
        self: *HttpPool,
        method: std.http.Method,
        uri: std.Uri,
        options: std.http.Client.RequestOptions,
    ) std.http.Client.RequestError!PooledRequest {
        self.refreshTlsClock();
        const io = self.client.io;
        self.setup_lock.lockSharedUncancelable(io);
        defer self.setup_lock.unlockShared(io);
        var pooled_options = options;
        const idle = if (options.connection == null) self.takeIdleConnection(uri) else null;
        if (idle) |connection| pooled_options.connection = connection;
        const request = self.client.request(method, uri, pooled_options) catch |err| {
            if (idle) |connection| self.client.connection_pool.release(connection, io);
            return err;
        };
        return .{ .request = request, .reused = idle != null };
    }

    fn takeIdleConnection(self: *HttpPool, uri: std.Uri) ?*std.http.Client.Connection {
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const criteria = originCriteria(uri, &host_buf) orelse return null;
        const proxy = switch (criteria.protocol) {
            .plain => self.client.http_proxy,
            .tls => self.client.https_proxy,
        };
        if (proxy != null) return null;
        const io = self.client.io;
        while (true) {
            const connection = (self.client.connection_pool.findConnection(io, criteria) catch |err| switch (err) {
                error.Canceled => {
                    io.recancel();
                    return null;
                },
            }) orelse return null;
            if (!addressGone(connection)) return connection;
            self.destroyTaken(io, connection);
            debug_trace.logf("gateway", "event=pool_drop_address_gone dropped=idle connection reason=its local address left the machine", .{});
        }
    }

    fn addressGone(connection: *std.http.Client.Connection) bool {
        const address = local_address.of(connection.stream_writer.stream.socket.handle) orelse return false;
        return local_address.missing(address);
    }

    fn destroyTaken(self: *HttpPool, io: std.Io, connection: *std.http.Client.Connection) void {
        self.client.connection_pool.mutex.lockUncancelable(io);
        self.client.connection_pool.used.remove(&connection.pool_node);
        self.client.connection_pool.mutex.unlock(io);
        connection.destroy(io);
    }

    fn refreshTlsClock(self: *HttpPool) void {
        const client = &self.client;
        const io = client.io;
        if (!self.setup_lock.tryLock(io)) return;
        defer self.setup_lock.unlock(io);
        client.ca_bundle_lock.lockUncancelable(io);
        defer client.ca_bundle_lock.unlock(io);

        if (client.now == null) return;
        client.now = std.Io.Clock.real.now(io);
    }

    fn drainIfStale(self: *HttpPool, url: []const u8) void {
        const last = self.last_activity_ms.load(.acquire);
        if (last == 0) return;
        const now = io_mod.milliTimestamp();
        const idle_ms = now - last;
        if (idle_ms <= self.ttl_ms) return;
        const drained = self.closeIdleConnections(url);

        self.last_activity_ms.store(now, .release);
        if (drained > 0) {
            debug_trace.logf("gateway", "pool_drain_stale count={d} idle_ms={d} ttl_ms={d}", .{ drained, idle_ms, self.ttl_ms });
        }
    }

    pub fn closeIdleConnections(self: *HttpPool, url: []const u8) usize {
        const io = io_mod.getIo();
        const uri = std.Uri.parse(url) catch return 0;
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const criteria = originCriteria(uri, &host_buf) orelse return 0;
        var closed: usize = 0;
        while (true) {
            const conn = (self.client.connection_pool.findConnection(io, criteria) catch |err| switch (err) {
                error.Canceled => {
                    io.recancel();
                    break;
                },
            }) orelse break;
            self.destroyTaken(io, conn);
            closed += 1;
        }
        return closed;
    }

    fn originCriteria(
        uri: std.Uri,
        host_buf: *[std.Io.net.HostName.max_len]u8,
    ) ?std.http.Client.ConnectionPool.Criteria {
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return null;
        const host = std.Io.net.HostName.fromUri(uri, host_buf) catch return null;
        return .{
            .host = host,
            .port = uri.port orelse defaultPort(protocol),
            .protocol = protocol,
        };
    }

    fn defaultPort(protocol: std.http.Client.Protocol) u16 {
        return switch (protocol) {
            .plain => 80,
            .tls => 443,
        };
    }
};

const PooledRequest = struct {
    request: std.http.Client.Request,
    reused: bool,
};

test "warm and drain tolerate malformed urls without touching the pool" {
    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();
    pool.warm("not a url");
    pool.warm("ftp://unsupported.example");
    _ = pool.clientFor("not a url");
    try std.testing.expectEqual(@as(i64, 0), pool.last_activity_ms.load(.acquire));
}

test "drainIfStale skips within-ttl and never-active pools" {
    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();
    pool.noteActivity();
    _ = pool.clientFor("https://ai-gateway.vercel.sh/v4/ai/language-model");
    const stamp = pool.last_activity_ms.load(.acquire);
    try std.testing.expect(stamp > 0);
    pool.ttl_ms = 0;
    _ = pool.clientFor("https://ai-gateway.vercel.sh/v4/ai/language-model");
    try std.testing.expect(pool.last_activity_ms.load(.acquire) >= stamp);
}

test "warmAsync is a no-op in test builds" {
    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();
    pool.warmAsync("https://127.0.0.1:1/unreachable");
    try std.testing.expect(!pool.warm_started.load(.acquire));
}

test "TLS clock refresh leaves an unloaded clock for std to load" {
    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();
    pool.refreshTlsClock();
    try std.testing.expect(pool.client.now == null);
}

test "TLS clock refresh skips while a connection setup reads the clock" {
    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();
    const io = pool.client.io;

    const stale = std.Io.Timestamp.fromNanoseconds(1);
    pool.client.now = stale;

    pool.setup_lock.lockSharedUncancelable(io);
    pool.refreshTlsClock();
    try std.testing.expectEqual(stale.nanoseconds, pool.client.now.?.nanoseconds);
    pool.setup_lock.unlockShared(io);

    const before = std.Io.Clock.real.now(io);
    pool.refreshTlsClock();
    try std.testing.expect(pool.client.now.?.nanoseconds >= before.nanoseconds);
}

test "openRequest advances a stale clock before connection setup" {
    const zio = io_mod.getIo();
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(zio, .{ .reuse_address = true });
    defer server.deinit(zio);
    const url = try std.testing.allocator.print("http://127.0.0.1:{d}/chat", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(url);

    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();
    pool.client.now = std.Io.Timestamp.fromNanoseconds(1);
    const before = std.Io.Clock.real.now(zio);

    var opened = try pool.openRequest(.POST, try std.Uri.parse(url), .{});
    defer opened.request.deinit();
    try std.testing.expect(pool.client.now.?.nanoseconds >= before.nanoseconds);
    try std.testing.expect(!opened.reused);
}

test "openRequest reports a reused idle connection and returns it to the pool" {
    const zio = io_mod.getIo();
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(zio, .{ .reuse_address = true });
    defer server.deinit(zio);
    const url = try std.testing.allocator.print("http://127.0.0.1:{d}/chat", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    const uri = try std.Uri.parse(url);

    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();

    pool.warm(url);
    try std.testing.expectEqual(@as(usize, 1), pool.freeConnectionCount());

    var opened = try pool.openRequest(.POST, uri, .{});
    try std.testing.expect(opened.reused);
    try std.testing.expectEqual(@as(usize, 0), pool.freeConnectionCount());
    opened.request.deinit();
    try std.testing.expectEqual(@as(usize, 1), pool.freeConnectionCount());

    try std.testing.expectEqual(@as(usize, 1), pool.closeIdleConnections(url));
    try std.testing.expectEqual(@as(usize, 0), pool.freeConnectionCount());
    try std.testing.expectEqual(@as(usize, 0), pool.closeIdleConnections("not a url"));
}

test "drain evicts a real parked connection past the TTL" {
    const zio = io_mod.getIo();
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(zio, .{ .reuse_address = true });
    defer server.deinit(zio);
    const url = try std.testing.allocator.print("http://127.0.0.1:{d}/chat", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(url);

    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();

    pool.warm(url);
    try std.testing.expectEqual(@as(usize, 1), pool.freeConnectionCount());

    pool.ttl_ms = 0;
    pool.last_activity_ms.store(io_mod.milliTimestamp() - 1000, .release);
    _ = pool.clientFor(url);
    try std.testing.expectEqual(@as(usize, 0), pool.freeConnectionCount());
}

test "openRequest closes an idle connection whose local address left the machine" {
    if (comptime !local_address.supported) return error.SkipZigTest;
    const zio = io_mod.getIo();
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(zio, .{ .reuse_address = true });
    defer server.deinit(zio);
    const url = try std.testing.allocator.print("http://127.0.0.1:{d}/chat", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    const uri = try std.Uri.parse(url);

    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();

    pool.warm(url);
    try std.testing.expectEqual(@as(usize, 1), pool.freeConnectionCount());

    local_address.test_missing = true;
    var opened = pool.openRequest(.POST, uri, .{}) catch |err| {
        local_address.test_missing = false;
        return err;
    };
    local_address.test_missing = false;

    try std.testing.expect(!opened.reused);
    try std.testing.expectEqual(@as(usize, 0), pool.freeConnectionCount());
    opened.request.deinit();
    try std.testing.expectEqual(@as(usize, 1), pool.freeConnectionCount());
}
