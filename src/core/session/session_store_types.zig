const std = @import("std");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_log = @import("session_log.zig");

const Allocator = std.mem.Allocator;

pub const automatic_legacy_max_bytes: u64 = 256 * 1024 * 1024;

pub const StorageFormat = enum {
    conversation,
    schema_v3,
    legacy_v1,
    legacy_v2,
};

pub const CandidateStorage = enum {
    conversation,
    schema_v3,
    legacy_v1,
    legacy_v2,
};

pub const ProjectionState = enum {
    current,
    stale,
    replayed,
    missing,
    invalid,
};

pub const DiscoveryCause = enum {
    listable,
    workspace_mismatch,
    authority_transition,
    missing_authority,
    invalid_authority,
    missing_manifest,
    invalid_manifest,
    unsupported_schema,
    legacy_too_large,
    unsafe_path,
};

pub const SessionSummary = struct {
    id: []u8,
    workspace_root: ?[]u8 = null,
    origin_workspace_root: ?[]u8 = null,
    title: ?[]u8 = null,
    preview: ?[]u8 = null,
    display_metadata_present: bool = false,
    created_at_ms: i64,
    updated_at_ms: i64,
    conversation_language: session.ConversationLanguage,
    history_len: usize,
    has_checkpoint: bool = false,
    has_managed_children: bool = false,
    last_prompt: ?[]u8 = null,
    archived: bool = false,
    archived_at_ms: ?i64 = null,
    last_turn_reason: ?[]u8 = null,

    pub fn hasResumableContent(self: SessionSummary) bool {
        return self.history_len != 0 or self.has_checkpoint or self.has_managed_children;
    }

    pub fn deinit(self: *SessionSummary, alloc: Allocator) void {
        alloc.free(self.id);
        if (self.workspace_root) |wr| alloc.free(wr);
        if (self.origin_workspace_root) |wr| alloc.free(wr);
        if (self.title) |title| alloc.free(title);
        if (self.preview) |preview| alloc.free(preview);
        if (self.last_prompt) |prompt| alloc.free(prompt);
        if (self.last_turn_reason) |reason| alloc.free(reason);
        self.* = undefined;
    }
};

pub const ResumableSessionContinuation = struct {
    updated_at_ms: i64,
    id: []const u8,
};

pub const ResumableSessionPage = struct {
    summaries: std.ArrayList(SessionSummary) = .empty,
    has_more: bool = false,

    pub fn deinit(self: *ResumableSessionPage, alloc: Allocator) void {
        for (self.summaries.items) |*summary| summary.deinit(alloc);
        self.summaries.deinit(alloc);
        self.* = undefined;
    }
};

pub const SessionListScope = enum {
    current_workspace,
    all_workspaces,
};

pub const SessionListPage = struct {
    summaries: std.ArrayList(SessionSummary) = .empty,
    has_more: bool = false,
    skipped_invalid: usize = 0,

    pub fn deinit(self: *SessionListPage, alloc: Allocator) void {
        for (self.summaries.items) |*summary| summary.deinit(alloc);
        self.summaries.deinit(alloc);
        self.* = undefined;
    }
};

pub const ResumeTarget = union(enum) {
    last,
    id: []const u8,
};

const transcript_suffix = ".jsonl";

pub fn sessionIdFromTranscriptPath(value: []const u8) ?[]const u8 {
    if (!std.Io.Dir.path.isAbsolute(value)) return null;
    if (!std.mem.endsWith(u8, value, transcript_suffix)) return null;
    const file = std.Io.Dir.path.basename(value);
    if (file.len <= transcript_suffix.len) return null;
    const stem = file[0 .. file.len - transcript_suffix.len];
    if (!std.mem.eql(u8, stem, "log") and !std.mem.eql(u8, stem, "events")) return stem;
    const folder = std.mem.trimEnd(u8, value[0 .. value.len - file.len], "/\\");
    const id = std.Io.Dir.path.basename(folder);
    return if (id.len == 0) null else id;
}

pub const ResumeOptions = struct {
    allow_large_legacy: bool = false,
};

pub const ReadOnlyDetail = struct {
    summary: SessionSummary,
    state: session_codec.DurableSessionState,
    storage_format: StorageFormat,
};

pub const SessionRecoveryStatus = enum {
    recovered,
    recovered_with_unverified_artifacts,
};

pub const SessionRecoveryResult = struct {
    source_session_id: []u8,
    recovered_session_id: []u8,
    history_len: usize,
    status: SessionRecoveryStatus = .recovered,
    permission_rules_dropped: bool = false,

    pub fn deinit(self: *SessionRecoveryResult, alloc: Allocator) void {
        alloc.free(self.source_session_id);
        alloc.free(self.recovered_session_id);
        self.* = undefined;
    }
};

pub const StoreContext = struct {
    sessions_dir: []const u8,
    home_dir: []const u8,
    workspace_root: []const u8,
    canonical_root: session_log.Root,
};
