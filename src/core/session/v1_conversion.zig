const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const image_attachments = @import("../images/image_attachments.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const session_event = @import("session_event.zig");
const session_codec = @import("session_codec.zig");
const session_log = @import("session_log.zig");
const session_store = @import("session_store.zig");
const session_catalog_cache = @import("session_catalog_cache.zig");
const session_layout = @import("session_layout.zig");
const session_child_store = @import("session_child_store.zig");
const relationship_index_codec = @import("session_relationship_index_codec.zig");
const result_store = @import("result_store.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const child_state = @import("../subagent/child_state.zig");
const json_decode = @import("../shared/json_decode.zig");
const sort_utils = @import("../shared/sort_utils.zig");

const Allocator = std.mem.Allocator;
const Event = session_event.ConversationEvent;

const trash_dir_name = "trash+v1";
const lock_file = "session.lock";
pub const lock_wait_ms: u64 = 2000;

pub const Problem = struct {
    pub const capacity = 512;

    buffer: [capacity]u8 = undefined,
    len: usize = 0,

    pub fn text(problem: *const Problem) []const u8 {
        return problem.buffer[0..problem.len];
    }

    pub fn set(problem: *Problem, comptime fmt: []const u8, args: anytype) error{InvalidSessionFormat} {
        problem.len = if (std.mem.print(&problem.buffer, fmt, args)) |written| written.len else |_| problem.buffer.len;
        return error.InvalidSessionFormat;
    }
};

const Kind = enum { absent, root, child };

pub fn kindOf(store: *session_store.Store, alloc: Allocator, id: []const u8) !Kind {
    session_layout.validateSessionId(id) catch return .absent;
    var dir = (try openMemberDir(store, id)) orelse return .absent;
    defer dir.close();
    const marked: ?bool = switch (try readMetadata(alloc, &dir)) {
        .missing => return .absent,

        .too_large => null,
        .bytes => |bytes| blk: {
            defer alloc.free(bytes);
            const Probe = struct { subagent_child: ?bool = null };
            const parsed = json_decode.parseFromSlice(Probe, alloc, bytes, .{ .ignore_unknown_fields = true }) catch break :blk null;
            defer parsed.deinit();
            break :blk parsed.value.subagent_child;
        },
    };
    return if (try child_state.isDiscoveredManagedChildSession(store.*, alloc, id, marked)) .child else .root;
}

pub fn kindProblem(store: *session_store.Store, alloc: Allocator, id: []const u8, err: anyerror, problem: *Problem) error{InvalidSessionFormat}!void {
    var dir = (openMemberDir(store, id) catch |open_err| return problem.set("its folder can't be opened ({s})", .{@errorName(open_err)})) orelse
        return problem.set("its folder is gone", .{});
    defer dir.close();
    const metadata = readMetadata(alloc, &dir) catch |read_err| return problem.set("session.json can't be read ({s})", .{@errorName(read_err)});
    switch (metadata) {
        .missing => return problem.set("session.json is missing", .{}),
        .too_large => {},
        .bytes => |bytes| {
            defer alloc.free(bytes);
            if (!(std.json.validate(alloc, bytes) catch false)) return problem.set("session.json is not valid JSON", .{});
            if (isConversationMetadata(alloc, bytes)) return problem.set("its subagent marker can't be read ({s})", .{@errorName(err)});
        },
    }
    return problem.set("session.json can't be read in any format this fx knows ({s})", .{@errorName(err)});
}

const Root = struct {
    id: []u8,
    unreadable: ?[]u8 = null,

    pub fn deinit(root: Root, alloc: Allocator) void {
        alloc.free(root.id);
        if (root.unreadable) |reason| alloc.free(reason);
    }
};

pub fn rootIds(alloc: Allocator, home: []const u8) ![]Root {
    var store = try session_store.Store.initReadOnlyFromHome(alloc, home, "/");
    defer store.deinit(alloc);
    var roots: std.ArrayList(Root) = .empty;
    errdefer {
        for (roots.items) |root| root.deinit(alloc);
        roots.deinit(alloc);
    }
    var candidates = store.readOnlyCandidates();
    while (true) {
        try roots.ensureUnusedCapacity(alloc, 1);
        const id = (try candidates.nextId(alloc, null)) orelse break;
        errdefer alloc.free(id);
        const kind = kindOf(&store, alloc, id) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                debug_trace.logf("convert", "action=KindUnknown session={s} err={s}", .{ id, @errorName(err) });
                var problem: Problem = .{};
                kindProblem(&store, alloc, id, err, &problem) catch {};
                roots.appendAssumeCapacity(.{ .id = id, .unreadable = try alloc.dupe(u8, problem.text()) });
                continue;
            },
        };
        if (kind != .root) {
            alloc.free(id);
            continue;
        }
        roots.appendAssumeCapacity(.{ .id = id });
    }
    return roots.toOwnedSlice(alloc);
}

pub const Stray = struct {
    id: []u8,
    parent: ?[]u8,
    parent_kind: enum { absent, child, unreadable },

    pub fn deinit(stray: Stray, alloc: Allocator) void {
        alloc.free(stray.id);
        if (stray.parent) |parent| alloc.free(parent);
    }
};

pub fn strayChildren(alloc: Allocator, home: []const u8) ![]Stray {
    var store = try session_store.Store.initReadOnlyFromHome(alloc, home, "/");
    defer store.deinit(alloc);
    var strays: std.ArrayList(Stray) = .empty;
    errdefer {
        for (strays.items) |stray| stray.deinit(alloc);
        strays.deinit(alloc);
    }
    var candidates = store.readOnlyCandidates();
    while (try candidates.nextId(alloc, null)) |id| {
        defer alloc.free(id);
        if ((kindOf(&store, alloc, id) catch continue) != .child) continue;
        const parent = parentOf(&store, alloc, id) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        errdefer if (parent) |value| alloc.free(value);
        const parent_kind: ?Kind = if (parent) |value| kindOf(&store, alloc, value) catch null else .absent;
        if (parent_kind == .root) {
            if (parent) |value| alloc.free(value);
            continue;
        }
        try strays.ensureUnusedCapacity(alloc, 1);
        strays.appendAssumeCapacity(.{ .id = try alloc.dupe(u8, id), .parent = parent, .parent_kind = if (parent_kind) |kind| switch (kind) {
            .child => .child,
            else => .absent,
        } else .unreadable });
    }
    return strays.toOwnedSlice(alloc);
}

fn parentOf(store: *session_store.Store, alloc: Allocator, id: []const u8) !?[]u8 {
    var dir = (try openMemberDir(store, id)) orelse return null;
    defer dir.close();
    var subagent = (try io_mod.openRealDirIfPresent(&dir, subagent_dir)) orelse return null;
    defer subagent.close();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "owner.json", "control.json" }) |name| {
        const bytes = (try readFileIfPresent(a, &subagent, name, child_state.max_state_bytes + 1)) orelse continue;
        const Named = struct { parent_id: ?[]const u8 = null };
        const named = json_decode.parseFromSliceLeaky(Named, a, bytes, .{ .ignore_unknown_fields = true }) catch continue;
        if (named.parent_id) |parent| return try alloc.dupe(u8, parent);
    }
    return null;
}

pub fn rememberedId(alloc: Allocator, home: []const u8, workspace: []const u8) !?[]u8 {
    var store = try session_store.Store.initReadOnlyFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    return store.readRememberedSessionId(alloc) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            debug_trace.logf("convert", "action=RememberedUnreadable err={s}", .{@errorName(err)});
            return error.RememberedSessionUnavailable;
        },
    };
}

pub fn readDetail(alloc: Allocator, home: []const u8, id: []const u8) !?session_store.ReadOnlyDetail {
    var store = try session_store.Store.initReadOnlyFromHome(alloc, home, "/");
    defer store.deinit(alloc);
    if (try kindOf(&store, alloc, id) != .root) return null;
    return try store.loadReadOnlyDetail(alloc, id, .{ .allow_large_legacy = true });
}

pub fn listRoots(alloc: Allocator, home: []const u8, active_id: ?[]const u8) !session_catalog_cache.ActionableSessionCatalog {
    var store = try session_store.Store.initReadOnlyFromHome(alloc, home, "/");
    defer store.deinit(alloc);
    const sessions = &(store.canonical_root.sessions orelse return .{});
    var catalog = try session_catalog_cache.listActionableCatalog(store, alloc, active_id);
    errdefer catalog.deinit(alloc);
    for (catalog.invalid_ids.items) |id| {
        const kind = kindOf(&store, alloc, id) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => blk: {
                debug_trace.logf("convert", "action=KindUnknown session={s} err={s}", .{ id, @errorName(err) });
                break :blk .root;
            },
        };
        if (kind != .root) continue;
        const changed_ms: i64 = if (sessions.dir.statFile(io_mod.getIo(), id, .{ .follow_symlinks = false })) |stat|
            std.math.cast(i64, @divFloor(stat.mtime.nanoseconds, std.time.ns_per_ms)) orelse 0
        else |err| blk: {
            debug_trace.logf("convert", "action=ListedWithoutTime session={s} err={s}", .{ id, @errorName(err) });
            break :blk 0;
        };
        const owned_id = try alloc.dupe(u8, id);
        catalog.summaries.append(alloc, .{
            .id = owned_id,
            .created_at_ms = changed_ms,
            .updated_at_ms = changed_ms,
            .conversation_language = types.ConversationLanguage.default(),
            .history_len = 0,
        }) catch |err| {
            alloc.free(owned_id);
            return err;
        };
    }
    return catalog;
}

pub fn hasUnreadable(alloc: Allocator, home: []const u8) !bool {
    var catalog = try listRoots(alloc, home, null);
    defer catalog.deinit(alloc);
    return catalog.invalid_ids.items.len > 0;
}

fn openMemberDir(store: *session_store.Store, id: []const u8) !?io_mod.VerifiedDir {
    const sessions = &(store.canonical_root.sessions orelse return null);

    return io_mod.openRealDirIfPresent(sessions, id);
}

pub fn hasFolder(home: []const u8, id: []const u8) !bool {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.print(&buffer, "{s}/{s}/{s}/{s}", .{ profile_paths.rootParent(home), profile_paths.rootName(), profile_paths.sessions_dir_name, id });
    _ = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{ .follow_symlinks = false }) catch |err| return switch (err) {
        error.FileNotFound => false,
        else => err,
    };
    return true;
}

pub const Locked = struct {
    id: []u8,
    dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,
};

pub fn releaseLocked(alloc: Allocator, locked: *Locked) void {
    locked.lock.release();
    locked.dir.close();
    alloc.free(locked.id);
}

pub const Family = struct {
    alloc: Allocator,
    members: std.ArrayList(Locked) = .empty,
    registry: child_state.Registry,
    absent: std.ArrayList([]u8) = .empty,

    pub fn release(family: *Family) void {
        for (family.members.items) |*member| releaseLocked(family.alloc, member);
        family.members.deinit(family.alloc);
        family.registry.deinit(family.alloc);
        for (family.absent.items) |id| family.alloc.free(id);
        family.absent.deinit(family.alloc);
        family.* = undefined;
    }

    pub fn isMember(family: *const Family, id: []const u8) bool {
        for (family.members.items) |member| if (std.mem.eql(u8, member.id, id)) return true;
        return false;
    }
};

pub fn lockFamily(alloc: Allocator, store: *session_store.Store, root_id: []const u8, wait_ms: u64, problem: *Problem) !Family {
    const started = io_mod.milliTimestamp();
    var family: Family = .{ .alloc = alloc, .registry = try child_state.Registry.init(alloc, root_id) };
    errdefer family.release();
    try family.members.ensureUnusedCapacity(alloc, 1);
    family.members.appendAssumeCapacity((try lockMember(alloc, store, root_id, started, wait_ms)) orelse return error.SessionNotFound);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var child_ids: std.ArrayList([]const u8) = .empty;
    if (try readRegistry(alloc, a, &family.members.items[0].dir, root_id, problem)) |registry| {
        family.registry.deinit(alloc);
        family.registry = registry;
        for (registry.children) |child| try child_ids.append(a, child.id);
    } else try indexedChildren(a, &family.members.items[0].dir, &child_ids, problem);
    for (child_ids.items) |child_id| {
        try family.members.ensureUnusedCapacity(alloc, 1);
        try family.absent.ensureUnusedCapacity(alloc, 1);
        if (try lockMember(alloc, store, child_id, started, wait_ms)) |locked| {
            family.members.appendAssumeCapacity(locked);
        } else family.absent.appendAssumeCapacity(try alloc.dupe(u8, child_id));
    }
    return family;
}

fn readRegistry(alloc: Allocator, a: Allocator, root: *io_mod.VerifiedDir, root_id: []const u8, problem: *Problem) !?child_state.Registry {
    var subagent = (try io_mod.openRealDirIfPresent(root, subagent_dir)) orelse return null;
    defer subagent.close();
    const bytes = (try readFileIfPresent(a, &subagent, "children.json", child_state.max_state_bytes + 1)) orelse return null;
    return child_state.parseRegistry(alloc, bytes, root_id) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return problem.set("subagent/children.json {s}", .{describe(a, bytes, err)}),
    };
}

fn indexedChildren(a: Allocator, root: *io_mod.VerifiedDir, ids: *std.ArrayList([]const u8), problem: *Problem) !void {
    var subagent = (try io_mod.openRealDirIfPresent(root, subagent_dir)) orelse return;
    defer subagent.close();
    const index_file = session_child_store.subagent_relationship_index_file;
    const header_bytes = (try readFileIfPresent(a, &subagent, index_file, relationship_index_codec.max_header_bytes + 1)) orelse return;
    const header = relationship_index_codec.decodeHeader(header_bytes) catch |err|
        return problem.set("subagent/{s} can't be read ({s})", .{ index_file, @errorName(err) });
    var offset: u64 = 0;
    var page_number: u64 = 0;
    while (offset < header.high_watermark) : (page_number += 1) {
        const page_name = relationship_index_codec.pageFileName(page_number);
        const page_bytes = (try readFileIfPresent(a, &subagent, &page_name, relationship_index_codec.max_page_bytes + 1)) orelse
            return problem.set("subagent/{s} is missing", .{&page_name});
        const page = relationship_index_codec.decodePage(page_bytes, page_number, header.storage_epoch) catch |err|
            return problem.set("subagent/{s} can't be read ({s})", .{ &page_name, @errorName(err) });
        const slots: usize = @intCast(@min(header.high_watermark - offset, relationship_index_codec.page_slots));
        for (page.slots[0..slots]) |*slot| {
            if (!slot.occupied) continue;
            const id = slot.childId();

            const known = for (ids.items) |known_id| {
                if (std.mem.eql(u8, known_id, id)) break true;
            } else false;
            if (!known) try ids.append(a, try a.dupe(u8, id));
        }
        offset += slots;
    }
}

const subagent_dir = "subagent";

fn lockMember(alloc: Allocator, store: *session_store.Store, id: []const u8, started: i64, wait_ms: u64) !?Locked {
    const dir = (try openMemberDir(store, id)) orelse return null;
    return lockOpened(alloc, store, id, dir, started, wait_ms);
}

fn lockOpened(alloc: Allocator, store: *session_store.Store, id: []const u8, opened: io_mod.VerifiedDir, started: i64, wait_ms: u64) !?Locked {
    var dir = opened;
    errdefer dir.close();
    const spent: u64 = @intCast(@max(io_mod.milliTimestamp() - started, 0));
    var lock = io_mod.acquireTimedAdvisoryLock(&dir, lock_file, wait_ms -| spent) catch |err| switch (err) {
        error.LockBusy => return error.SessionBusy,

        error.FileNotFound => {
            debug_trace.logf("convert", "action=Vanished session={s}", .{id});
            dir.close();
            return null;
        },
        else => return err,
    };
    errdefer lock.release();
    if (!try stillInPlace(store, id, &dir)) {
        debug_trace.logf("convert", "action=Vanished session={s}", .{id});
        lock.release();
        dir.close();
        return null;
    }
    return .{ .id = try alloc.dupe(u8, id), .dir = dir, .lock = lock };
}

fn stillInPlace(store: *session_store.Store, id: []const u8, dir: *io_mod.VerifiedDir) !bool {
    const io = io_mod.getIo();
    const sessions = &(store.canonical_root.sessions orelse return false);
    const named = sessions.dir.statFile(io, id, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return named.kind == .directory and named.inode == (try dir.dir.stat(io)).inode;
}

pub fn tryLockLeftover(alloc: Allocator, store: *session_store.Store, id: []const u8) !?Locked {
    return lockMember(alloc, store, id, io_mod.milliTimestamp(), 0) catch |err| switch (err) {
        error.SessionBusy => null,
        else => err,
    };
}

const Step = union(enum) {
    framed: Framed,
    whole: Whole,
    compacted: Compacted,
};

const Framed = struct {
    events: []const Event,
    seqs: []const u64,
    open: bool,
    ts_ms: u64,
};

const Whole = struct {
    turn: types.HistoryTurn,
    ts_ms: u64,
};

const Compacted = struct {
    summary: []const u8,
    removed_turn_count: usize,
    compaction_count: usize,
    keep_from: ?usize,
    keep_tool_steps: usize = 0,
    keep_steering: usize = 0,
    ts_ms: u64,
};

pub const Member = struct {
    arena: std.heap.ArenaAllocator,
    workspace: []const u8,
    created_ms: u64,
    listed_ms: u64,
    language: types.ConversationLanguage,
    preferences: session_codec.DurableSessionPreferences,
    title: ?[]const u8,
    permissions: session_permission_state.State,
    rules_dropped: bool,
    steps: []const Step,
    turns: usize,
    stored: []const Stored,
    fingerprint: [64]u8,

    pub fn deinit(member: *Member) void {
        member.arena.deinit();
        member.* = undefined;
    }
};

pub const Stored = struct {
    key: []const u8,
    bytes: []const u8,
};

pub const Rules = enum { required, drop_unreadable };

pub fn readMember(gpa: Allocator, store: *session_store.Store, locked: *Locked, problem: *Problem, rules: Rules) !Member {
    var member: Member = undefined;
    member.arena = .init(gpa);
    errdefer member.arena.deinit();
    const a = member.arena.allocator();
    member.stored = &.{};
    member.rules_dropped = false;
    member.fingerprint = fingerprintOf(a, &locked.dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return problem.set("its folder can't be read ({s})", .{@errorName(err)}),
    };
    const metadata = readMetadata(a, &locked.dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return problem.set("session.json can't be read ({s})", .{@errorName(err)}),
    };
    switch (metadata) {
        .missing => return problem.set("session.json is missing", .{}),

        .too_large => try readOlderFormat(a, store, locked, &member, problem),
        .bytes => |bytes| {
            if (!(std.json.validate(a, bytes) catch false)) return problem.set("session.json is not valid JSON", .{});
            if (isConversationMetadata(a, bytes)) {
                try readConversation(a, locked, bytes, &member, problem, rules);
            } else try readOlderFormat(a, store, locked, &member, problem);
        },
    }
    member.turns = countTurns(member.steps);
    return member;
}

fn countTurns(steps: []const Step) usize {
    var turns: usize = 0;
    for (steps) |step| {
        if (step != .compacted) turns += 1;
    }
    return turns;
}

pub fn readSalvage(gpa: Allocator, store: *session_store.Store, locked: *Locked, problem: *Problem) !Member {
    var member: Member = undefined;
    member.arena = .init(gpa);
    errdefer member.arena.deinit();
    const a = member.arena.allocator();
    member.stored = &.{};
    member.rules_dropped = false;
    member.fingerprint = fingerprintOf(a, &locked.dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return problem.set("its folder can't be read ({s})", .{@errorName(err)}),
    };
    var recoverable = try store.recoverableState(a, &locked.dir, locked.id);
    member.listed_ms = @intCast(@max(recoverable.state.updated_at_ms, 0));
    member.title = recoverable.title;
    try fromState(a, locked, &recoverable.state, "events.jsonl", &member, problem);
    member.turns = countTurns(member.steps);
    return member;
}

const Metadata = union(enum) { missing, too_large, bytes: []u8 };

fn readMetadata(alloc: Allocator, dir: *io_mod.VerifiedDir) !Metadata {
    const bytes = readFileIfPresent(alloc, dir, "session.json", session_codec.max_session_metadata_bytes + 1) catch |err| switch (err) {
        error.StreamTooLong => return .too_large,
        else => return err,
    };
    return if (bytes) |value| .{ .bytes = value } else .missing;
}

fn isConversationMetadata(a: Allocator, bytes: []const u8) bool {
    const Probe = struct { schema_version: u64 = 0 };
    const probe = json_decode.parseFromSliceLeaky(Probe, a, bytes, .{ .ignore_unknown_fields = true }) catch return false;
    return probe.schema_version == session_codec.session_metadata_schema_version;
}

fn readConversation(a: Allocator, locked: *Locked, metadata_bytes: []const u8, member: *Member, problem: *Problem, rules: Rules) !void {
    const metadata = session_codec.decodeSessionMetadata(a, metadata_bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return problem.set("session.json {s}", .{describe(a, metadata_bytes, err)}),
    };
    const value = metadata.value;
    if (!std.mem.eql(u8, value.id, locked.id)) return problem.set("session.json names another session", .{});
    member.workspace = value.workspace_root;
    member.created_ms = @intCast(@max(value.created_at_ms, 0));
    member.language = types.ConversationLanguage.fromSlice(value.conversation_language) catch
        return problem.set("session.json has an unknown conversation language", .{});
    member.preferences = .{
        .provider = value.provider,
        .model = try a.dupe(u8, value.model),
        .effort = types.ReasoningEffort.parse(value.effort) orelse return problem.set("session.json has an unknown effort", .{}),
        .fast_mode = value.fast_mode,
        .ultrafast_mode = value.ultrafast_mode orelse false,
    };
    member.title = value.title;
    member.permissions = readPermissions(a, &locked.dir, problem) catch |err| switch (rules) {
        .required => return err,
        .drop_unreadable => if (err == error.OutOfMemory) return err else dropped: {
            problem.* = .{};
            member.rules_dropped = true;
            break :dropped .{};
        },
    };

    var frames: FrameReader = .{ .arena = a, .dir = &locked.dir, .id = locked.id, .problem = problem, .builder = .init(a) };
    defer frames.builder.deinit();
    try frames.readAll();
    try frames.finish();
    member.steps = frames.steps.items;
    member.listed_ms = listedTime(&locked.dir, value.updated_at_ms, frames.steps.items.len > 0);
}

fn readPermissions(a: Allocator, dir: *io_mod.VerifiedDir, problem: *Problem) !session_permission_state.State {
    const state = session_log.loadConversationPermissionState(a, dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return problem.set("permissions.json can't be read ({s})", .{@errorName(err)}),
    };

    if (state.version == session_permission_state.schema_version) return state;
    return session_permission_state.migrateV1ToV2(a, state) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return problem.set("permissions.json can't be migrated ({s})", .{@errorName(err)}),
    };
}

fn listedTime(dir: *io_mod.VerifiedDir, updated_at_ms: i64, has_history: bool) u64 {
    var listed = updated_at_ms;
    if (has_history) {
        if (dir.dir.statFile(io_mod.getIo(), "events.jsonl", .{ .follow_symlinks = false })) |stat| {
            const changed = std.math.cast(i64, @divFloor(stat.mtime.nanoseconds, std.time.ns_per_ms)) orelse std.math.maxInt(i64);
            listed = @max(listed, changed);
        } else |_| {}
    }
    return @intCast(@max(listed, 0));
}

const FrameReader = struct {
    arena: Allocator,
    dir: *io_mod.VerifiedDir,
    id: []const u8,
    problem: *Problem,
    builder: session_log.ConversationTurnBuilder,
    steps: std.ArrayList(Step) = .empty,
    turn_last_seq: std.ArrayList(u64) = .empty,
    turn_steps: std.ArrayList(usize) = .empty,
    open: std.ArrayList(Event) = .empty,
    open_seqs: std.ArrayList(u64) = .empty,
    open_user_seq: ?u64 = null,
    deferred_compactions: std.ArrayList(Step) = .empty,
    compactions: usize = 0,
    last_seq: u64 = 0,
    last_ts: u64 = 0,
    line: usize = 0,

    fn readAll(reader: *FrameReader) !void {
        const io = io_mod.getIo();

        var file = io_mod.openExistingReadOnlyRegularFile(reader.dir.dir, "events.jsonl", .no_follow) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return reader.problem.set("events.jsonl can't be opened ({s})", .{@errorName(err)}),
        };
        defer file.close(io);
        const log = blk: {
            const length = file.length(io) catch |err| return reader.problem.set("events.jsonl can't be read ({s})", .{@errorName(err)});

            const limit = std.math.cast(usize, length +| 1) orelse return error.OutOfMemory;
            break :blk io_mod.readFileToEnd(reader.arena, &file, limit) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return reader.problem.set("events.jsonl can't be read ({s})", .{@errorName(err)}),
            };
        };

        var rest = log;
        while (std.mem.findScalar(u8, rest, '\n')) |newline| {
            reader.line += 1;
            try reader.frame(rest[0 .. newline + 1]);
            rest = rest[newline + 1 ..];
        }
    }

    fn frame(reader: *FrameReader, bytes: []const u8) !void {
        const envelope = session_event.decodeConversationFrameLeaky(reader.arena, bytes, .alloc_if_needed) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.InvalidConversationFrame => return reader.problem.set("events.jsonl line {d} {s}", .{
                reader.line,
                if (std.json.validate(reader.arena, std.mem.trimEnd(u8, bytes, "\n")) catch false) "is not a valid event" else "is not valid JSON",
            }),
        };
        if (envelope.seq != reader.last_seq + 1) return reader.problem.set("events.jsonl line {d} is out of order", .{reader.line});
        reader.last_seq = envelope.seq;
        const ts: u64 = @intCast(envelope.timestamp_ms);
        reader.last_ts = @max(reader.last_ts, ts);
        reader.apply(envelope.event, envelope.seq) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,

            error.InvalidSessionFormat => return error.InvalidSessionFormat,
            else => return reader.problem.set("events.jsonl line {d} does not fit its turn ({s})", .{ reader.line, @errorName(err) }),
        };
    }

    fn apply(reader: *FrameReader, event: Event, seq: u64) !void {
        const a = reader.arena;
        switch (event) {
            .user => |value| {
                if (reader.open_user_seq != null) return error.InvalidConversationFrame;
                try reader.builder.begin(value);
                reader.open_user_seq = seq;
                var user = value;
                user.images = try withImages(a, reader.dir, reader.id, value.images, reader.problem);
                try reader.keep(.{ .user = user }, seq);
            },
            .assistant => |value| {
                try reader.requireOpen();
                try reader.builder.appendAssistant(value);
                try reader.keep(event, seq);
            },
            .tool_call => |value| {
                try reader.requireOpen();
                try reader.builder.appendToolCall(value);
                try reader.keep(event, seq);
            },
            .tool_result => |value| {
                try reader.requireOpen();
                try reader.builder.appendToolResult(value);
                try reader.keep(event, seq);
            },
            .steering => |value| {
                try reader.requireOpen();
                try reader.builder.appendSteering(value.text);
                try reader.keep(event, seq);
            },

            .context_note, .runtime_context, .model_call => return error.InvalidConversationFrame,

            .turn_completed => |value| {
                try reader.requireOpen();
                _ = try reader.builder.finishAssistant(value);
                try reader.end(event, seq);
            },
            .interrupted => |value| {
                try reader.requireOpen();
                _ = try reader.builder.finishInterrupted(value);
                try reader.end(event, seq);
            },
            .context_checkpoint => |checkpoint| {
                try reader.builder.finishStandalone();
                reader.compactions += 1;

                var prior: usize = 0;
                var keep_from: ?usize = null;
                for (reader.turn_last_seq.items, 0..) |last, index| {
                    if (last <= checkpoint.covers_through_seq) {
                        prior += 1;
                    } else if (keep_from == null) keep_from = index;
                }

                const covered: types.ContextHistoryCut = if (keep_from) |index| blk: {
                    const turn = reader.steps.items[reader.turn_steps.items[index]].framed;
                    break :blk try coveredSteps(turn.events, turn.seqs, checkpoint.covers_through_seq);
                } else if (reader.open_user_seq != null)
                    try coveredSteps(reader.open.items, reader.open_seqs.items, checkpoint.covers_through_seq)
                else
                    .{};
                const step: Step = .{ .compacted = .{
                    .summary = checkpoint.summary,
                    .removed_turn_count = prior,
                    .compaction_count = reader.compactions,
                    .keep_from = keep_from,
                    .keep_tool_steps = covered.tool_steps,
                    .keep_steering = covered.steering,
                    .ts_ms = reader.last_ts,
                } };

                if (reader.open_user_seq != null) try reader.deferred_compactions.append(a, step) else try reader.steps.append(a, step);
            },
        }
    }

    fn keep(reader: *FrameReader, event: Event, seq: u64) !void {
        try reader.open.append(reader.arena, event);
        try reader.open_seqs.append(reader.arena, seq);
    }

    fn requireOpen(reader: *const FrameReader) error{InvalidConversationFrame}!void {
        if (reader.open_user_seq == null) return error.InvalidConversationFrame;
    }

    fn end(reader: *FrameReader, event: Event, seq: u64) !void {
        try reader.keep(event, seq);
        try reader.flushDeferredCompactions();
        try reader.turn_steps.append(reader.arena, reader.steps.items.len);
        try reader.steps.append(reader.arena, .{ .framed = .{
            .events = try reader.open.toOwnedSlice(reader.arena),
            .seqs = try reader.open_seqs.toOwnedSlice(reader.arena),
            .open = false,
            .ts_ms = reader.last_ts,
        } });
        try reader.turn_last_seq.append(reader.arena, seq);
        reader.open_user_seq = null;
    }

    fn flushDeferredCompactions(reader: *FrameReader) !void {
        try reader.steps.appendSlice(reader.arena, reader.deferred_compactions.items);
        reader.deferred_compactions.clearRetainingCapacity();
    }

    fn finish(reader: *FrameReader) !void {
        const a = reader.arena;
        const checkpoint = session_log.loadConversationRecoveryCheckpoint(a, reader.dir, reader.last_seq) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return reader.problem.set("recovery.json can't be read ({s})", .{@errorName(err)}),
        };

        if (checkpoint != null and reader.open_user_seq != null) for (reader.deferred_compactions.items) |*step| switch (step.*) {
            .compacted => |*compacted| if (compacted.keep_from == null) {
                compacted.keep_tool_steps = 0;
                compacted.keep_steering = 0;
            },
            else => {},
        };
        try reader.flushDeferredCompactions();
        if (reader.open_user_seq == null) {
            if (checkpoint != null) debug_trace.logf("convert", "action=RecoveryDropped session={s} reason=turn_not_open", .{reader.id});
            return;
        }
        if (checkpoint) |value| {
            var kept = value;

            if (kept.user.work_id == null) {
                if (reader.open.items[0].user.work_id) |work_id| kept.user.work_id = try a.dupe(u8, work_id);
            }
            kept.user.images = try withImages(a, reader.dir, reader.id, kept.user.images, reader.problem);
            try reader.steps.append(a, .{ .whole = .{ .turn = kept.interruptedTurn(), .ts_ms = reader.last_ts } });
            return;
        }
        try reader.steps.append(a, .{ .framed = .{
            .events = try reader.open.toOwnedSlice(a),
            .seqs = try reader.open_seqs.toOwnedSlice(a),
            .open = true,
            .ts_ms = reader.last_ts,
        } });
    }
};

fn coveredSteps(events: []const Event, seqs: []const u64, coverage: u64) !types.ContextHistoryCut {
    var progress: session_log.ConversationProgress = .{};
    for (events, seqs) |event, seq| {
        if (seq > coverage) break;
        try progress.observe(seq, event, null);
    }

    if (progress.pending_assistant) |assistant| {
        if (assistant.seq == coverage) progress.point.tool_steps += 1;
    }
    return .{ .tool_steps = progress.point.tool_steps, .steering = progress.point.steering };
}

fn readOlderFormat(a: Allocator, store: *session_store.Store, locked: *Locked, member: *Member, problem: *Problem) !void {
    var detail = store.loadReadOnlyDetail(a, locked.id, .{ .allow_large_legacy = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return problem.set("session.json can't be read in any format this fx knows ({s})", .{@errorName(err)}),
    };
    member.listed_ms = @intCast(@max(detail.summary.updated_at_ms, 0));
    member.title = detail.summary.title;

    const history_file: []const u8 = if (locked.dir.dir.statFile(io_mod.getIo(), "authority.json", .{ .follow_symlinks = false })) |_| "events.jsonl" else |_| "session.json";
    try fromState(a, locked, &detail.state, history_file, member, problem);
}

fn fromState(a: Allocator, locked: *Locked, state: *session_codec.DurableSessionState, history_file: []const u8, member: *Member, problem: *Problem) !void {
    member.workspace = state.workspace_root;
    member.created_ms = @intCast(@max(state.created_at_ms, 0));
    member.language = state.conversation_language;
    member.preferences = state.preferences;
    member.permissions = state.permission_state;
    if (state.permission_state.version != session_permission_state.schema_version) {
        member.permissions = session_permission_state.migrateV1ToV2(a, state.permission_state) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return problem.set("permissions can't be migrated ({s})", .{@errorName(err)}),
        };
    }

    if (!try state.archive_legacy_recovery(a) and state.recovery_checkpoint != null)
        debug_trace.logf("convert", "action=RecoveryDropped session={s} reason=older_format", .{locked.id});
    _ = try session_log.discardEmptyLegacyFileEvidence(a, state.history);
    var stored: std.ArrayList(Stored) = .empty;
    var steps: std.ArrayList(Step) = .empty;
    const ts_floor: u64 = member.created_ms;
    var last_ts: u64 = ts_floor;
    for (state.history, 1..) |*turn, number| {
        switch (turn.*) {
            inline .assistant, .interrupted => |*entry| {
                entry.user.images = try withImages(a, &locked.dir, locked.id, entry.user.images, problem);
                try storeInline(a, &entry.execution, &stored);
            },
            .compacted_summary => {},
        }
        try requireKeepable(a, turn.*, history_file, number, problem);
        last_ts = @max(last_ts, turnTime(turn.*));
        try steps.append(a, switch (turn.*) {
            .compacted_summary => |summary| .{ .compacted = .{
                .summary = summary.summary,
                .removed_turn_count = summary.removed_turn_count,
                .compaction_count = summary.compaction_count,
                .keep_from = null,
                .ts_ms = last_ts,
            } },
            .assistant, .interrupted => .{ .whole = .{ .turn = turn.*, .ts_ms = last_ts } },
        });
    }
    member.steps = steps.items;
    member.stored = stored.items;
}

fn requireKeepable(a: Allocator, turn: types.HistoryTurn, file: []const u8, number: usize, problem: *Problem) !void {
    const user = switch (turn) {
        .assistant => |entry| entry.user,
        .interrupted => |entry| entry.user,
        .compacted_summary => return,
    };
    if (!std.unicode.utf8ValidateSlice(user.text))
        return problem.set("{s} turn {d} has a prompt that is not valid UTF-8, which the current format can't keep", .{ file, number });
    var events: std.ArrayList(Event) = .empty;
    session_event.appendHistoryTurnConversationEvents(a, &events, turn) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return problem.set("{s} turn {d} has a field the current format can't keep ({s})", .{ file, number, @errorName(err) }),
    };
    for (events.items) |event| session_event.validateConversationEventShape(event, session_event.conversation_schema_version) catch |err|
        return problem.set("{s} turn {d} has a field the current format can't keep ({s})", .{ file, number, @errorName(err) });
}

fn storeInline(a: Allocator, execution: *types.ExecutionMemory, stored: *std.ArrayList(Stored)) !void {
    for (execution.tool_steps) |*step| for (step.tool_results) |*result| {
        if (result.output_handle == null) {
            const handle = try result_store.makeHandle(a, result.tool_call_id, result.tool_name, result.output);
            try stored.append(a, .{ .key = try a.print("tool-results/{s}", .{handle}), .bytes = result.output });
            result.output_handle = handle;
            result.truncated = true;
            result.stored_output_bytes = result.output.len;
        }
        if (result.preview == null) result.preview = try result_store.previewText(a, result.output, result_store.preview_bytes);
    };
}

fn turnTime(turn: types.HistoryTurn) u64 {
    const summary = switch (turn) {
        .assistant => |entry| entry.execution.turn_summary,
        .interrupted => |entry| entry.execution.turn_summary,
        .compacted_summary => null,
    } orelse return 0;
    return @intCast(@max(summary.completed_at_ms, 0));
}

fn withImages(a: Allocator, dir: *io_mod.VerifiedDir, id: []const u8, images: []const types.ImageAttachment, problem: *Problem) ![]types.ImageAttachment {
    var kept: std.ArrayList(types.ImageAttachment) = try .initCapacity(a, images.len);
    for (images) |source| {
        var image = source;
        if (image.inline_data == null and image.snapshot_path == null) {
            if (try capturePathOnly(a, id, &image)) kept.appendAssumeCapacity(image);
            continue;
        }
        defer kept.appendAssumeCapacity(image);
        if (image.inline_data != null) continue;
        const leaf = snapshotLeaf(image.snapshot_path.?, id) orelse continue;
        const bytes = blk: {
            var images_dir = (io_mod.openRealDirIfPresent(dir, "images") catch |err|
                return problem.set("images can't be opened ({s})", .{@errorName(err)})) orelse break :blk null;
            defer images_dir.close();
            break :blk readFileIfPresent(a, &images_dir, leaf, max_image_bytes + 1) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return problem.set("images/{s} can't be read ({s})", .{ leaf, @errorName(err) }),
            };
        };
        image.inline_data = bytes orelse {
            debug_trace.logf("convert", "action=ImageLost session={s} image={s}", .{ id, leaf });
            continue;
        };
        image.snapshot_path = null;
    }
    return kept.items;
}

fn capturePathOnly(a: Allocator, id: []const u8, image: *types.ImageAttachment) !bool {
    const folder = try image_attachments.createTempSnapshotDir(a);
    defer std.Io.Dir.cwd().deleteTree(io_mod.getIo(), folder) catch |err|
        debug_trace.logf("convert", "action=ImageCaptureLeftover session={s} err={s}", .{ id, @errorName(err) });
    image_attachments.captureImageSnapshot(a, image, folder) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("convert", "action=ImageDropped session={s} image={d} err={s}", .{ id, image.id, @errorName(err) });
            return false;
        },
    };
    try image_attachments.inlineCapturedSnapshot(a, image);
    image.snapshot_path = null;
    return true;
}

const max_image_bytes = 64 * 1024 * 1024;

fn snapshotLeaf(path: []const u8, id: []const u8) ?[]const u8 {
    const prefix = "images/";
    const leaf = if (std.mem.startsWith(u8, path, prefix)) path[prefix.len..] else blk: {
        const at = std.mem.findLast(u8, path, "/" ++ prefix) orelse return null;
        const folder = path[0..at];
        if (!std.mem.endsWith(u8, folder, id) or (folder.len > id.len and folder[folder.len - id.len - 1] != '/')) return null;
        break :blk path[at + 1 + prefix.len ..];
    };
    if (leaf.len == 0 or std.mem.findAny(u8, leaf, "/\\") != null or std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..")) return null;
    return leaf;
}

const not_content = [_][]const u8{ lock_file, "owner.live", "recovery.asked", "commit.lock", "history-cache.bin" };

pub fn fingerprintOf(a: Allocator, dir: *io_mod.VerifiedDir) ![64]u8 {
    const io = io_mod.getIo();
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const skip = for (not_content) |name| {
            if (std.mem.eql(u8, name, entry.name)) break true;
        } else false;
        if (!skip) try names.append(a, try a.dupe(u8, entry.name));
    }
    sort_utils.sort([]const u8, names.items, {}, lessThan);
    for ([_][]const u8{ "subagent/children.json", "client/system-prompt.txt", "client/mcp-tool-identities.json" }) |name| try names.append(a, name);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    for (names.items) |name| {
        var file = io_mod.openExistingReadOnlyRegularFile(dir.dir, name, .no_follow) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer file.close(io);
        hash.update(name);
        hash.update(&.{0});
        var offset: u64 = 0;
        while (true) {
            const n = try file.readPositional(io, &.{&buffer}, offset);
            if (n == 0) break;
            hash.update(buffer[0..n]);
            offset += n;
        }
        var size: [8]u8 = undefined;
        std.mem.writeInt(u64, &size, offset, .little);
        hash.update(&size);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

pub fn removeFolder(store: *session_store.Store, id: []const u8, why: []const u8) bool {
    const io = io_mod.getIo();
    const sessions = &(store.canonical_root.sessions orelse return false);
    var trash = io_mod.openOrCreateVerifiedPrivateDir(sessions, trash_dir_name) catch |err| {
        debug_trace.logf("convert", "action=DeleteRefused session={s} why={s} step=trash err={s}", .{ id, why, @errorName(err) });
        return false;
    };
    defer trash.close();

    trash.dir.deleteTree(io, id) catch |err|
        debug_trace.logf("convert", "action=TrashKept entry={s} err={s}", .{ id, @errorName(err) });
    std.Io.Dir.rename(sessions.dir, id, trash.dir, id, io) catch |err| {
        debug_trace.logf("convert", "action=DeleteRefused session={s} why={s} step=rename err={s}", .{ id, why, @errorName(err) });
        return false;
    };
    trash.dir.deleteTree(io, id) catch |err| {
        debug_trace.logf("convert", "action=DeleteRefused session={s} why={s} step=remove err={s}", .{ id, why, @errorName(err) });
        return true;
    };
    debug_trace.logf("convert", "action=Deleted session={s} why={s}", .{ id, why });
    return true;
}

pub fn emptyTrash(alloc: Allocator, store: *session_store.Store) void {
    const io = io_mod.getIo();
    const sessions = &(store.canonical_root.sessions orelse return);
    var trash = (io_mod.openVerifiedPrivateDirIfPresent(sessions, trash_dir_name) catch |err| {
        debug_trace.logf("convert", "action=TrashKept entry=- err={s}", .{@errorName(err)});
        return;
    }) orelse return;
    defer trash.close();
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| alloc.free(name);
        names.deinit(alloc);
    }
    var it = trash.dir.iterate();
    while (it.next(io) catch |err| {
        debug_trace.logf("convert", "action=TrashKept entry=- err={s}", .{@errorName(err)});
        return;
    }) |entry| {
        names.ensureUnusedCapacity(alloc, 1) catch |err| {
            debug_trace.logf("convert", "action=TrashKept entry={s} err={s}", .{ entry.name, @errorName(err) });
            return;
        };
        names.appendAssumeCapacity(alloc.dupe(u8, entry.name) catch |err| {
            debug_trace.logf("convert", "action=TrashKept entry={s} err={s}", .{ entry.name, @errorName(err) });
            return;
        });
    }
    for (names.items) |name| trash.dir.deleteTree(io, name) catch |err| {
        debug_trace.logf("convert", "action=TrashKept entry={s} err={s}", .{ name, @errorName(err) });
    };
}

fn readFileIfPresent(a: Allocator, dir: *io_mod.VerifiedDir, name: []const u8, max_bytes: usize) !?[]u8 {
    var file = io_mod.openExistingReadOnlyRegularFile(dir.dir, name, .no_follow) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    return try io_mod.readFileToEnd(a, &file, max_bytes);
}

fn describe(a: Allocator, bytes: []const u8, err: anyerror) []const u8 {
    if (!(std.json.validate(a, bytes) catch false)) return "is not valid JSON";
    return @errorName(err);
}

test "a checkpoint inside a turn covers that turn's steps and steering as v1's writer counted them (D87)" {
    const result = struct {
        fn of(id: []const u8) Event {
            return .{ .tool_result = .{ .call_id = id, .tool_name = "Bash", .status = .success, .artifact_ref = "", .stored_bytes = 0, .completeness = .complete } };
        }
    };
    const events = [_]Event{
        .{ .user = .{ .text = "go" } },
        .{ .assistant = .{ .text = "plan" } },
        .{ .tool_call = .{ .call_id = "c1", .tool_name = "Bash", .arguments_json = "{}" } },
        result.of("c1"),
        .{ .steering = .{ .text = "faster" } },
        .{ .assistant = .{ .text = "a reply with no tool call" } },
        .{ .assistant = .{ .text = "then one more" } },
        .{ .tool_call = .{ .call_id = "c2", .tool_name = "Bash", .arguments_json = "{}" } },
        result.of("c2"),
    };
    const seqs = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };

    try std.testing.expectEqual(types.ContextHistoryCut{ .tool_steps = 1 }, try coveredSteps(&events, &seqs, 4));
    try std.testing.expectEqual(types.ContextHistoryCut{ .tool_steps = 1, .steering = 1 }, try coveredSteps(&events, &seqs, 5));
    try std.testing.expectEqual(types.ContextHistoryCut{ .tool_steps = 2, .steering = 1 }, try coveredSteps(&events, &seqs, 6));
    try std.testing.expectEqual(types.ContextHistoryCut{ .tool_steps = 3, .steering = 1 }, try coveredSteps(&events, &seqs, 9));
}

test "a member folder another process removes after it is opened and before it is locked is gone, not an error (D61)" {
    const alloc = std.testing.allocator;
    const io = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".fx/sessions/v1memberid01");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var store = try session_store.Store.initReadOnlyFromHome(alloc, home, "/");
    defer store.deinit(alloc);
    const opened = (try openMemberDir(&store, "v1memberid01")).?;

    try tmp.dir.deleteTree(io, ".fx/sessions/v1memberid01");
    try std.testing.expectEqual(@as(?Locked, null), try lockOpened(alloc, &store, "v1memberid01", opened, io_mod.milliTimestamp(), 0));
}

test "an older turn the current event format cannot keep names its file, turn and cause" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var problem: Problem = .{};

    const turn: types.HistoryTurn = .{ .assistant = .{ .user = .{ .text = @constCast("bad \xff byte") }, .assistant = @constCast("answer") } };
    try std.testing.expectError(error.InvalidSessionFormat, requireKeepable(arena.allocator(), turn, "events.jsonl", 3, &problem));
    try std.testing.expectEqualStrings("events.jsonl turn 3 has a prompt that is not valid UTF-8, which the current format can't keep", problem.text());
    const fine: types.HistoryTurn = .{ .assistant = .{ .user = .{ .text = @constCast("fine") }, .assistant = @constCast("answer") } };
    try requireKeepable(arena.allocator(), fine, "events.jsonl", 1, &problem);
}
