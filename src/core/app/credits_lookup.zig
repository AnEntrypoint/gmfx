const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const secret = @import("../auth/secret.zig");
const credentials = @import("../auth/credentials.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const output_contracts = @import("../output/output_contracts.zig");

pub const Start = enum { started, busy };

const renewal_failed_message = "Could not renew the sign-in to check credits. Try again.";
const renewal_sign_in_message = "Your sign-in has expired. Run /login, then check credits again.";

pub const Renewal = struct {
    transport: oauth_transport.Provider,
    source: credentials.Source,
    account_id: ?[]const u8,
};

pub const Result = struct {
    snapshot: output_contracts.CreditsSnapshot,
    renewed: ?credentials.Credential = null,

    pub fn deinit(self: *Result) void {
        self.snapshot.deinit(std.heap.c_allocator);
        if (self.renewed) |*credential| credential.deinit(std.heap.c_allocator);
        self.* = undefined;
    }
};

pub const Lookup = struct {
    task: ?*Task = null,

    pub fn start(
        self: *Lookup,
        provider: gateway_provider.CreditsProvider,
        input: gateway_provider.CreditsLookupInput,
        renewal: ?Renewal,
    ) !Start {
        if (self.task != null) return .busy;
        self.task = try Task.start(provider, input, renewal);
        return .started;
    }

    pub fn take(self: *Lookup) ?Result {
        const task = self.task orelse return null;
        if (!task.done.load(.acquire)) return null;
        self.task = null;
        return task.finish();
    }

    pub fn deinit(self: *Lookup) void {
        const task = self.task orelse return;
        self.task = null;
        if (!task.done.load(.acquire)) {
            debug_trace.logf("credits", "lookup dropped reason=shutdown", .{});
        }
        task.cancel.store(true, .seq_cst);
        var result = task.finish();
        result.deinit();
    }
};

const Task = struct {
    provider: gateway_provider.CreditsProvider,
    credential: ?[]u8,
    credential_source: ?credentials.Source,
    tenant: ?[]u8,
    renewal: ?Renewal,
    renewal_account_id: ?[]u8,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    result: Result = .{ .snapshot = .{} },
    future: std.Io.Future(void) = undefined,

    fn start(
        provider: gateway_provider.CreditsProvider,
        input: gateway_provider.CreditsLookupInput,
        renewal: ?Renewal,
    ) !*Task {
        const alloc = std.heap.c_allocator;
        const task = try alloc.create(Task);
        errdefer alloc.destroy(task);
        const credential = if (input.credential) |value| try alloc.dupe(u8, value) else null;
        errdefer if (credential) |value| secret.zeroAndFree(alloc, value);
        const tenant = if (input.tenant) |value| try alloc.dupe(u8, value) else null;
        errdefer if (tenant) |value| alloc.free(value);
        const account_id = if (renewal) |value| if (value.account_id) |id| try alloc.dupe(u8, id) else null else null;
        errdefer if (account_id) |id| alloc.free(id);
        task.* = .{
            .provider = provider,
            .credential = credential,
            .credential_source = input.credential_source,
            .tenant = tenant,
            .renewal = renewal,
            .renewal_account_id = account_id,
        };
        task.future = try io_mod.getIo().concurrent(run, .{task});
        return task;
    }

    fn run(self: *Task) void {
        const alloc = std.heap.c_allocator;
        var credential: ?[]const u8 = self.credential;
        var tenant: ?[]const u8 = self.tenant;
        if (self.renewal) |renewal| {
            var transport: oauth_transport.Cancellable = .{ .inner = renewal.transport, .cancel_flag = &self.cancel };
            const renewed = auth_runtime.refreshCredentialForAccount(
                transport.provider(),
                alloc,
                renewal.source,
                .if_needed,
                self.renewal_account_id,
            ) catch |err| {
                debug_trace.logf("credits", "lookup could not renew source={t} err={s}", .{ renewal.source, @errorName(err) });
                const message = if (auth_runtime.classifyCredentialFailure(renewal.source, err).requiresSignIn())
                    renewal_sign_in_message
                else
                    renewal_failed_message;
                self.result.snapshot = .{ .err_message = alloc.dupe(u8, message) catch null };
                self.done.store(true, .release);
                return;
            };
            if (renewed) |value| {
                self.result.renewed = value;
                credential = value.token;
                tenant = value.gatewayTeam();
            }
        }
        self.result.snapshot = self.provider.fetch(alloc, .{
            .credential = credential,
            .credential_source = self.credential_source,
            .tenant = tenant,
            .cancel_flag = &self.cancel,
        });
        self.done.store(true, .release);
    }

    fn finish(self: *Task) Result {
        self.future.await(io_mod.getIo());
        const result = self.result;
        const alloc = std.heap.c_allocator;
        if (self.credential) |value| secret.zeroAndFree(alloc, value);
        if (self.tenant) |value| alloc.free(value);
        if (self.renewal_account_id) |id| alloc.free(id);
        alloc.destroy(self);
        return result;
    }
};

const TestProvider = struct {
    release: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(usize) = .init(0),
    saw_input: std.atomic.Value(bool) = .init(false),

    fn provider(self: *TestProvider) gateway_provider.CreditsProvider {
        return .{ .context = self, .fetch_fn = fetch };
    }

    fn fetch(
        raw: ?*anyopaque,
        alloc: std.mem.Allocator,
        input: gateway_provider.CreditsLookupInput,
    ) output_contracts.CreditsSnapshot {
        const self: *TestProvider = @ptrCast(@alignCast(raw.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        self.saw_input.store(
            std.mem.eql(u8, input.credential orelse "", "credential") and
                std.mem.eql(u8, input.tenant orelse "", "tenant") and
                input.cancel_flag != null,
            .seq_cst,
        );

        while (!self.release.load(.seq_cst) and !input.cancel_flag.?.load(.seq_cst)) {
            std.Thread.yield() catch {};
        }
        if (input.cancel_flag.?.load(.seq_cst)) {
            return .{ .err_message = alloc.dupe(u8, "cancelled") catch null };
        }
        return .{ .balance = alloc.dupe(u8, "42") catch null };
    }
};

fn takeWhenDone(lookup: *Lookup) Result {
    while (true) {
        if (lookup.take()) |result| return result;
        std.Thread.yield() catch {};
    }
}

test "credits lookup hands over its finished snapshot once" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var fake: TestProvider = .{};
    var lookup: Lookup = .{};
    defer lookup.deinit();

    var credential = "credential".*;
    try std.testing.expectEqual(Start.started, try lookup.start(fake.provider(), .{
        .credential = &credential,
        .tenant = "tenant",
    }, null));

    @memset(&credential, 'x');
    try std.testing.expect(lookup.take() == null);

    fake.release.store(true, .seq_cst);
    var result = takeWhenDone(&lookup);
    defer result.deinit();
    try std.testing.expectEqualStrings("42", result.snapshot.balance.?);
    try std.testing.expect(result.renewed == null);
    try std.testing.expect(fake.saw_input.load(.seq_cst));
    try std.testing.expect(lookup.take() == null);
}

test "credits lookup reports busy while one runs" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var fake: TestProvider = .{};
    var lookup: Lookup = .{};
    defer lookup.deinit();

    try std.testing.expectEqual(Start.started, try lookup.start(fake.provider(), .{ .credential = null, .tenant = null }, null));
    try std.testing.expectEqual(Start.busy, try lookup.start(fake.provider(), .{ .credential = null, .tenant = null }, null));

    fake.release.store(true, .seq_cst);
    var result = takeWhenDone(&lookup);
    result.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.calls.load(.seq_cst));
    try std.testing.expectEqual(Start.started, try lookup.start(fake.provider(), .{ .credential = null, .tenant = null }, null));
}

test "credits lookup shutdown cancels a stalled fetch and waits for it" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var fake: TestProvider = .{};
    var lookup: Lookup = .{};

    try std.testing.expectEqual(Start.started, try lookup.start(fake.provider(), .{ .credential = null, .tenant = null }, null));
    while (fake.calls.load(.seq_cst) == 0) std.Thread.yield() catch {};
    lookup.deinit();

    try std.testing.expect(lookup.task == null);
    try std.testing.expect(!fake.release.load(.seq_cst));
}
