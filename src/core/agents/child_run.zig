const std = @import("std");
const subagent_domain = @import("../subagent/domain.zig");
const subagent_authority = @import("../subagent/authority.zig");
const credentials = @import("../auth/credentials.zig");
const subagent_execution = @import("../subagent/execution.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const ChildRun = struct {
    child_id: []u8,
    subagent_id: u64 = 0,
    admission: subagent_domain.AdmissionSnapshot,
    authority_resolver: *subagent_authority.Resolver,
    system_prompt: []u8 = &.{},
    credential: ?credentials.Credential = null,
    root_user_intent_context: []u8 = &.{},
    root_user_messages: [][]u8 = &.{},
    root_user_evidence_complete: bool = false,
    work_id: []u8 = &.{},
    turn: ?*subagent_execution.TurnContext = null,
    completion: ?*Completion = null,
    failure: ?types.ModelFailureDiagnostic = null,
    ended_as: ?types.TurnPresentationOutcome = null,
    handed_off: bool = false,
    turn_work_id: []u8 = &.{},

    pub fn inFlight(self: *const ChildRun) bool {
        return self.completion != null;
    }

    pub fn startedByParent(self: *const ChildRun) bool {
        return self.work_id.len > 0;
    }

    pub fn finish(self: *ChildRun, outcome: Completion.Outcome) void {
        const completion = self.completion orelse return;
        self.turn = null;
        self.completion = null;
        completion.finish(outcome);
    }

    pub fn deinit(self: *ChildRun, alloc: Allocator) void {
        self.finish(.cancelled);
        alloc.free(self.child_id);
        alloc.free(self.work_id);
        alloc.free(self.turn_work_id);
        self.admission.deinit(alloc);
        alloc.free(self.system_prompt);
        if (self.credential) |*credential| credential.deinit(alloc);
        alloc.free(self.root_user_intent_context);
        for (self.root_user_messages) |message| alloc.free(message);
        alloc.free(self.root_user_messages);
        self.* = undefined;
    }
};

pub const Completion = struct {
    mutex: std.Io.Mutex = .init,
    outcome: ?Outcome = null,
    done: std.Io.Event = .unset,

    pub const Outcome = enum { completed, failed, cancelled };

    pub fn finish(self: *Completion, outcome: Outcome) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.outcome == null) self.outcome = outcome;
        self.done.set(io_mod.getIo());
    }

    pub fn result(self: *Completion) ?Outcome {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.outcome;
    }
};

fn testRun(alloc: Allocator, completion: *Completion) !ChildRun {
    return .{
        .child_id = try alloc.dupe(u8, "child"),
        .admission = try subagent_domain.captureAdmission(alloc, .{
            .parent_id = "parent",
            .source_id = "parent",
            .model = "test-model",
            .effort = .auto,
        }),
        .authority_resolver = undefined,
        .completion = completion,
    };
}

test "ending a child's run releases its slot thread once, with the first outcome" {
    const alloc = std.testing.allocator;
    var completion: Completion = .{};
    var run = try testRun(alloc, &completion);
    defer run.deinit(alloc);
    try std.testing.expect(run.inFlight());
    try std.testing.expectEqual(@as(?Completion.Outcome, null), completion.result());

    run.finish(.completed);
    try std.testing.expect(!run.inFlight());
    try std.testing.expectEqual(@as(?Completion.Outcome, .completed), completion.result());

    run.finish(.failed);
    completion.finish(.cancelled);
    try std.testing.expectEqual(@as(?Completion.Outcome, .completed), completion.result());
}

test "freeing a child's run still in flight ends it as cancelled" {
    const alloc = std.testing.allocator;
    var completion: Completion = .{};
    var run = try testRun(alloc, &completion);
    run.deinit(alloc);
    try std.testing.expectEqual(@as(?Completion.Outcome, .cancelled), completion.result());
}
