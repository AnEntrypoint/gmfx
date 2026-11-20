const std = @import("std");
const builtin = @import("builtin");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const elicitation = @import("../mcp/elicitation.zig");
const runtime_mod = @import("runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;

pub const Runtime = runtime_mod.Runtime;
pub const Options = runtime_mod.Options;
pub const Catalog = model.Catalog;
pub const Notify = runtime_mod.Notify;
pub const Notice = runtime_mod.Notice;
pub const Status = runtime_mod.Status;
pub const signalServersForExit = runtime_mod.signalServersForExit;
pub const waitRetired = runtime_mod.waitRetired;
pub const menu = @import("menu.zig");

pub const Extras = struct {
    questions: elicitation.Capabilities = .{},
    notify: ?runtime_mod.Notify = null,
    slash_commands: bool = false,
    reuse: ?*Host = null,
    session_open: bool = false,
};

pub const LoadFn = *const fn (
    gpa: Allocator,
    workspace_root: []const u8,
    builtins: tool_dispatch.Registry,
    extras: Extras,
) anyerror!?*Host;

pub const Host = struct {
    gpa: Allocator,
    runtime: Runtime,
    catalog: Catalog,
    notes: []const []const u8 = &.{},
    notes_mutex: std.Io.Mutex = .init,
    leases: usize = 0,
    retired: bool = false,

    pub fn create(
        gpa: Allocator,
        io: std.Io,
        configs: []const mcp_contract.McpServerConfig,
        inherited: *const std.process.Environ.Map,
        options: Options,
        builtins: tool_dispatch.Registry,
    ) !*Host {
        const h = try gpa.create(Host);
        errdefer gpa.destroy(h);
        h.gpa = gpa;
        h.notes = &.{};
        h.notes_mutex = .init;
        h.leases = 0;
        h.retired = false;
        try h.runtime.start(gpa, io, configs, inherited, options);
        errdefer h.runtime.deinit();
        try h.catalog.init(gpa, io, &h.runtime, builtins);
        return h;
    }

    pub fn destroy(h: *Host) void {
        const gpa = h.gpa;
        freeNotes(gpa, h.notes);
        h.catalog.deinit();
        h.runtime.deinit();
        gpa.destroy(h);
    }

    pub fn reload(
        h: *Host,
        configs: []const mcp_contract.McpServerConfig,
        inherited: *const std.process.Environ.Map,
        notes: []const []const u8,
    ) !void {
        h.notes_mutex.lockUncancelable(h.runtime.io);
        const old = h.notes;
        h.notes = notes;
        h.notes_mutex.unlock(h.runtime.io);
        freeNotes(h.gpa, old);
        try h.catalog.reload(try h.runtime.reload(configs, inherited));
    }

    fn freeNotes(gpa: Allocator, notes: []const []const u8) void {
        for (notes) |note| gpa.free(note);
        gpa.free(notes);
    }

    pub fn retire(h: *Host) void {
        h.runtime.retire();
    }

    pub fn stop(h: *Host) void {
        h.retire();

        if (comptime builtin.single_threaded) return h.destroy();
        const thread = std.Thread.spawn(.{}, destroy, .{h}) catch |err| {
            debug_trace.logf("mcp", "MCP host stopped in place err={s}", .{@errorName(err)});
            return h.destroy();
        };
        thread.detach();
    }
};

test {
    _ = model;
    _ = runtime_mod;
}
