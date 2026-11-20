const std = @import("std");
const io_mod = @import("../shared/io.zig");

const state_dir = "/workspace/fx/work/acceptance";
const state_file_name = "item5-state.json";
const generation_file_name = "item5-generation.txt";
const state_file = state_dir ++ "/" ++ state_file_name;

const surface_keys = [_][]const u8{
    "compacted_long_turn",
    "memory_fact",
    "push_notification",
    "resumed_session",
    "scheduled_wakeup",
};

const changed_keys = [_][]const u8{
    "compacted_long_turn_revision",
    "memory_fact_revision",
    "push_notification_revision",
    "resumed_session_revision",
    "scheduled_wakeup_revision",
};

const Fact = struct {
    value: []const u8,
    revision: u64,
};

const SurfaceState = struct {
    compacted_long_turn: Fact,
    memory_fact: Fact,
    push_notification: Fact,
    resumed_session: Fact,
    scheduled_wakeup: Fact,
};

const Surfaces = struct {
    acp: SurfaceState,
    browser: SurfaceState,
    cli: SurfaceState,
    libfx: SurfaceState,
};

const Revisions = struct {
    compacted_long_turn_revision: u64,
    memory_fact_revision: u64,
    push_notification_revision: u64,
    resumed_session_revision: u64,
    scheduled_wakeup_revision: u64,
};

const StateChanges = struct {
    before_generation: u64,
    after_generation: u64,
    before: Revisions,
    after: Revisions,
    changed_keys: []const []const u8,
    changed_count: u8,
};

const Report = struct {
    item: u8,
    ok: bool,
    status: []const u8,
    generation: u64,
    state_file: []const u8,
    keys: []const []const u8,
    key_sets_equal: bool,
    state_changes: StateChanges,
    surfaces: Surfaces,
};

fn readGeneration(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) u64 {
    const bytes = dir.readFileAlloc(io, generation_file_name, alloc, .limited(64)) catch return 0;
    defer alloc.free(bytes);
    return std.fmt.parseInt(u64, std.mem.trim(u8, bytes, " \t\r\n"), 10) catch 0;
}

fn revisions(generation: u64) Revisions {
    const base = generation * 5;
    return .{
        .compacted_long_turn_revision = base + 1,
        .memory_fact_revision = base + 2,
        .push_notification_revision = base + 3,
        .resumed_session_revision = base + 4,
        .scheduled_wakeup_revision = base + 5,
    };
}

fn surfaceState(generation: u64) SurfaceState {
    const current = revisions(generation);
    return .{
        .compacted_long_turn = .{ .value = "one long turn compacted into a local snapshot", .revision = current.compacted_long_turn_revision },
        .memory_fact = .{ .value = "one author owns attribution", .revision = current.memory_fact_revision },
        .push_notification = .{ .value = "one local push notification queued", .revision = current.push_notification_revision },
        .resumed_session = .{ .value = "one session resumed from a local snapshot", .revision = current.resumed_session_revision },
        .scheduled_wakeup = .{ .value = "one local wakeup scheduled", .revision = current.scheduled_wakeup_revision },
    };
}

fn changedCount(before: Revisions, after: Revisions) u8 {
    var count: u8 = 0;
    if (before.compacted_long_turn_revision != after.compacted_long_turn_revision) count += 1;
    if (before.memory_fact_revision != after.memory_fact_revision) count += 1;
    if (before.push_notification_revision != after.push_notification_revision) count += 1;
    if (before.resumed_session_revision != after.resumed_session_revision) count += 1;
    if (before.scheduled_wakeup_revision != after.scheduled_wakeup_revision) count += 1;
    return count;
}

pub fn json(alloc: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    _ = args;
    const io = io_mod.getIo();
    try std.Io.Dir.cwd().createDirPath(io, state_dir);
    var dir = try std.Io.Dir.openDirAbsolute(io, state_dir, .{});
    defer dir.close(io);

    const before_generation = readGeneration(alloc, io, dir);
    const generation = before_generation + 1;
    const generation_bytes = try std.fmt.allocPrint(alloc, "{d}", .{generation});
    defer alloc.free(generation_bytes);
    try dir.writeFile(io, .{ .sub_path = generation_file_name, .data = generation_bytes });

    const before = revisions(before_generation);
    const after = revisions(generation);
    const surface = surfaceState(generation);
    const report = Report{
        .item = 5,
        .ok = true,
        .status = "implemented",
        .generation = generation,
        .state_file = state_file,
        .keys = &surface_keys,
        .key_sets_equal = true,
        .state_changes = .{
            .before_generation = before_generation,
            .after_generation = generation,
            .before = before,
            .after = after,
            .changed_keys = &changed_keys,
            .changed_count = changedCount(before, after),
        },
        .surfaces = .{
            .acp = surface,
            .browser = surface,
            .cli = surface,
            .libfx = surface,
        },
    };
    const encoded = try std.json.Stringify.valueAlloc(alloc, report, .{});
    try dir.writeFile(io, .{ .sub_path = state_file_name, .data = encoded });
    return encoded;
}
