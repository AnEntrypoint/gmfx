const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const specs = @import("specs.zig");
const set_goal_budget_impl = @import("set_goal_budget.zig");
const update_goal_impl = @import("update_goal.zig");

pub const create_goal = specs.create_goal;
pub const get_goal = specs.get_goal;
pub const set_goal_budget = specs.set_goal_budget;
pub const update_goal = specs.update_goal;
pub const all = specs.all;

pub fn stopsBatch(kind: tool_dispatch.ExecutorKind, input: tool_dispatch.ToolInput) bool {
    return switch (kind) {
        .set_goal_budget => set_goal_budget_impl.stopsBatch(input),
        .update_goal => update_goal_impl.stopsBatch(input),
        else => false,
    };
}

pub fn stopsTurn(kind: tool_dispatch.ExecutorKind, input: tool_dispatch.ToolInput) bool {
    return switch (kind) {
        .set_goal_budget => set_goal_budget_impl.stopsTurn(input),
        .update_goal => update_goal_impl.stopsTurn(input),
        else => false,
    };
}

test {
    _ = @import("create_goal.zig");
    _ = @import("get_goal.zig");
    _ = @import("set_goal_budget.zig");
    _ = @import("update_goal.zig");
    _ = @import("serialize.zig");
    _ = @import("shared.zig");
    _ = @import("specs.zig");
}
