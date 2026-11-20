const std = @import("std");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const compaction_activity = @import("../output/compaction_activity.zig");
const text_utils = @import("../shared/text_utils.zig");

pub const PendingPhase = enum {
    awaiting_frame,
    awaiting_adoption,
    adopted,
    awaiting_auth,
    queued,
};

pub const PendingPhaseError = error{InvalidPendingPhase};

pub const PendingPromptDraft = struct {
    turn_id: u64,
    prompt: []u8,
    images: []types.ImageAttachment,
    skill_display_spans: []worker_runtime.SkillDisplaySpan,

    pub fn deinit(self: PendingPromptDraft, alloc: std.mem.Allocator) void {
        alloc.free(self.prompt);
        types.freeImageAttachmentSlice(alloc, self.images);
        worker_runtime.freeSkillDisplaySpans(alloc, self.skill_display_spans);
    }
};

pub const PendingSubmission = struct {
    draft: PendingPromptDraft,
    phase: PendingPhase = .awaiting_frame,
    credential_admitted: bool = false,
    skill_refresh_generation: ?u64 = null,

    pub fn init(draft: PendingPromptDraft) PendingSubmission {
        std.debug.assert(draft.turn_id != 0);
        return .{ .draft = draft };
    }

    pub fn deinit(self: *PendingSubmission, alloc: std.mem.Allocator) void {
        self.draft.deinit(alloc);
        self.* = undefined;
    }

    pub fn ownsTurnStartHold(self: PendingSubmission) bool {
        return self.phase != .queued;
    }

    pub fn markFrameCommitted(self: *PendingSubmission) bool {
        if (self.phase != .awaiting_frame) return false;
        self.phase = .awaiting_adoption;
        return true;
    }

    pub fn markAdopted(self: *PendingSubmission) PendingPhaseError!void {
        if (self.phase != .awaiting_adoption) return error.InvalidPendingPhase;
        self.phase = .adopted;
    }

    pub fn markQueued(self: *PendingSubmission) bool {
        if (self.phase != .adopted) return false;
        self.phase = .queued;
        return true;
    }
};

pub const PendingSkillRefresh = enum {
    pending,
    current,
};

pub const State = struct {
    pending: ?PendingSubmission = null,
    launch_prompt: ?[]u8 = null,
    retry_after_auth: bool = false,
    compaction_pending: bool = false,
    compaction_operation: ?compaction_activity.OperationId = null,
    compaction_instruction_bytes: [max_compaction_instruction_bytes]u8 = undefined,
    compaction_instruction_len: usize = 0,

    pub fn setCompactionInstruction(self: *State, text: []const u8) void {
        const kept = text_utils.utf8PrefixByBytes(std.mem.trim(u8, text, " \t\r\n"), max_compaction_instruction_bytes);
        @memcpy(self.compaction_instruction_bytes[0..kept.len], kept);
        self.compaction_instruction_len = kept.len;
    }

    pub fn compactionInstruction(self: *const State) []const u8 {
        return self.compaction_instruction_bytes[0..self.compaction_instruction_len];
    }
};

pub const max_compaction_instruction_bytes: usize = 2048;

test "a compaction instruction is trimmed, capped, and replaced by the next /compact" {
    var state: State = .{};
    try std.testing.expectEqualStrings("", state.compactionInstruction());
    state.setCompactionInstruction("  keep the schema decisions \n");
    try std.testing.expectEqualStrings("keep the schema decisions", state.compactionInstruction());
    var overlong: [max_compaction_instruction_bytes + 10]u8 = undefined;
    @memset(&overlong, 'x');
    state.setCompactionInstruction(&overlong);
    try std.testing.expectEqual(max_compaction_instruction_bytes, state.compactionInstruction().len);
    state.setCompactionInstruction("");
    try std.testing.expectEqualStrings("", state.compactionInstruction());
}
