const tool_specs = @import("../../core/tooling/tool_specs.zig");
const model_tool_schema = @import("../../core/tooling/model_tool_schema.zig");
const create_goal_impl = @import("create_goal.zig");
const get_goal_impl = @import("get_goal.zig");
const set_goal_budget_impl = @import("set_goal_budget.zig");
const update_goal_impl = @import("update_goal.zig");

const ToolSpec = tool_specs.ToolSpec;

const create_goal_schema = model_tool_schema.ObjectSchema{
    .properties = &.{
        .{ .name = "objective", .json_type = .string, .description = "The objective to pursue. Must have a verifiable end state.", .bounds = &.{ .min_length = 1 } },
        .{ .name = "completionCriterion", .json_type = .string, .description = "How to verify the goal is complete. Include when the user provides one." },
        .{ .name = "replace", .json_type = .boolean, .description = "Replace an existing active, paused, or blocked goal instead of failing." },
    },
    .required = &.{"objective"},
    .additional_properties = false,
};

const get_goal_schema = model_tool_schema.ObjectSchema{
    .properties = &.{},
    .additional_properties = false,
};

const set_goal_budget_schema = model_tool_schema.ObjectSchema{
    .properties = &.{
        .{ .name = "value", .json_type = .integer, .description = "The positive numeric budget value." },
        .{ .name = "unit", .json_type = .string, .shape = &.{ .enum_values = &.{ "turns", "tokens", "milliseconds", "seconds", "minutes", "hours" } } },
    },
    .required = &.{ "value", "unit" },
    .additional_properties = false,
};

const update_goal_schema = model_tool_schema.ObjectSchema{
    .properties = &.{
        .{ .name = "status", .json_type = .string, .description = "The lifecycle status to set for the current goal. Use `blocked` for impossible, unsafe, or contradictory objectives, or after the same non-terminal blocking condition repeats for at least 3 consecutive goal turns.", .shape = &.{ .enum_values = &.{ "active", "complete", "blocked" } } },
    },
    .required = &.{"status"},
    .additional_properties = false,
};

pub const create_goal = ToolSpec{
    .name = "CreateGoal",
    .description = create_goal_impl.description,
    .model_schema = .{
        .name = "CreateGoal",
        .description = create_goal_impl.description,
        .input_schema = create_goal_schema,
    },
    .executor_kind = .create_goal,
    .model_visible = false,
    .activity_kind = .read,
    .requires_approval = false,
    .action_label = "Creating goal",
    .completed_action_label = "Created goal",
    .permission_target_kind = .none,
    .decode = create_goal_impl.decode,
    .call = create_goal_impl.call,
    .reads_only_fn = create_goal_impl.readsOnly,
    .irreversible_fn = create_goal_impl.isIrreversible,
};

pub const get_goal = ToolSpec{
    .name = "GetGoal",
    .description = get_goal_impl.description,
    .model_schema = .{
        .name = "GetGoal",
        .description = get_goal_impl.description,
        .input_schema = get_goal_schema,
    },
    .executor_kind = .get_goal,
    .model_visible = false,
    .activity_kind = .read,
    .requires_approval = false,
    .action_label = "Reading goal",
    .completed_action_label = "Read goal",
    .permission_target_kind = .none,
    .decode = get_goal_impl.decode,
    .call = get_goal_impl.call,
    .reads_only_fn = get_goal_impl.readsOnly,
    .irreversible_fn = get_goal_impl.isIrreversible,
};

pub const set_goal_budget = ToolSpec{
    .name = "SetGoalBudget",
    .description = set_goal_budget_impl.description,
    .model_schema = .{
        .name = "SetGoalBudget",
        .description = set_goal_budget_impl.description,
        .input_schema = set_goal_budget_schema,
    },
    .executor_kind = .set_goal_budget,
    .model_visible = false,
    .activity_kind = .read,
    .requires_approval = false,
    .action_label = "Setting goal budget",
    .completed_action_label = "Set goal budget",
    .permission_target_kind = .none,
    .decode = set_goal_budget_impl.decode,
    .call = set_goal_budget_impl.call,
    .reads_only_fn = set_goal_budget_impl.readsOnly,
    .irreversible_fn = set_goal_budget_impl.isIrreversible,
};

pub const update_goal = ToolSpec{
    .name = "UpdateGoal",
    .description = update_goal_impl.description,
    .model_schema = .{
        .name = "UpdateGoal",
        .description = update_goal_impl.description,
        .input_schema = update_goal_schema,
    },
    .executor_kind = .update_goal,
    .model_visible = false,
    .activity_kind = .read,
    .requires_approval = false,
    .action_label = "Updating goal",
    .completed_action_label = "Updated goal",
    .permission_target_kind = .none,
    .decode = update_goal_impl.decode,
    .call = update_goal_impl.call,
    .reads_only_fn = update_goal_impl.readsOnly,
    .irreversible_fn = update_goal_impl.isIrreversible,
};

pub const all = [_]ToolSpec{ create_goal, get_goal, set_goal_budget, update_goal };
