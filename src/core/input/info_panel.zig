const std = @import("std");
const output_contracts = @import("../output/output_contracts.zig");
const types = @import("../shared/types.zig");

pub const Row = output_contracts.PanelRow;

pub const Kind = enum {
    status,
    permissions,

    pub fn title(self: Kind) []const u8 {
        return switch (self) {
            .status => "Status",
            .permissions => "Permissions",
        };
    }
};

pub const Facts = union(Kind) {
    status: struct {
        history_turns: usize,
        session_saved: ?bool,
        session_grants: usize,
        plan_mode: ?bool = null,
    },
    permissions: struct {
        mode: types.PermissionMode,
        session_grants: usize,
        configured_rules: usize,
    },
};

pub const Inputs = union(Kind) {
    status: struct {
        preferred: ?types.CredentialSource,
        settings_error: ?[]const u8,
    },
    permissions,
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    rows: []const Row,
    facts: Facts,
    inputs: Inputs,

    pub fn kind(self: *const Snapshot) Kind {
        return self.facts;
    }

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const State = struct {
    active: bool = false,
    scroll: usize = 0,
    snapshot: ?Snapshot = null,

    pub fn open(self: *State, snapshot: Snapshot) void {
        self.close();
        self.* = .{ .active = true, .snapshot = snapshot };
    }

    pub fn replace(self: *State, snapshot: Snapshot) void {
        if (self.snapshot) |*old| old.deinit();
        self.snapshot = snapshot;
    }

    pub fn close(self: *State) void {
        if (self.snapshot) |*old| old.deinit();
        self.* = .{};
    }

    pub fn title(self: *const State) []const u8 {
        return if (self.snapshot) |*snapshot| snapshot.kind().title() else "";
    }

    pub fn rows(self: *const State) []const Row {
        return if (self.snapshot) |*snapshot| snapshot.rows else &.{};
    }

    pub fn scrollBy(self: *State, delta: i32, total_lines: usize, visible_lines: usize) bool {
        if (!self.active or delta == 0) return false;
        const last_start = total_lines -| @max(visible_lines, 1);
        const start = @min(self.scroll, last_start);
        const next = if (delta > 0) @min(start +| 1, last_start) else start -| 1;
        if (next == self.scroll) return false;
        self.scroll = next;
        return true;
    }
};
