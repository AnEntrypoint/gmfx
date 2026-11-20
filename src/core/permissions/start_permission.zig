const std = @import("std");
const types = @import("../shared/types.zig");

const PermissionMode = types.PermissionMode;

pub const create_goal_tool_name = "CreateGoal";
pub const cancelled_format = "Tool \"{s}\" was not run because the approval request was cancelled.";
pub const goal_subject_prefix = "Start goal: ";
pub const goal_criterion_prefix = "Done when: ";
pub const mode_notice_format = "Permission mode: {s}";
pub const fixed_row_count: u8 = 3;

pub const Kind = enum { goal, swarm };

pub const Choice = enum {
    never_ask,
    ask_when_needed,
    always_ask,
    cancel,

    pub fn mode(self: Choice) ?PermissionMode {
        return switch (self) {
            .never_ask => .auto,
            .ask_when_needed => .yolo,
            .always_ask => .ask,
            .cancel => null,
        };
    }
};

pub const Option = struct {
    choice: Choice,
    label: []const u8,
    row_label: []const u8,
    description: []const u8,
};

fn option(comptime number: u8, comptime choice: Choice, comptime label: []const u8, comptime description: []const u8) Option {
    return .{
        .choice = choice,
        .label = label,
        .row_label = std.fmt.comptimePrint("{d}. {s}", .{ number, label }),
        .description = description,
    };
}

pub const Variant = struct {
    kind: Kind,
    title: []const u8,
    notice_lines: [2][]const u8,
    options: []const Option,
    extra_row_labels: []const []const u8,

    pub fn optionAt(self: *const Variant, choice_index: u8) ?Option {
        return if (choice_index < self.options.len) self.options[choice_index] else null;
    }

    pub fn rowLabel(self: *const Variant, choice_index: u8) []const u8 {
        return if (self.optionAt(choice_index)) |found| found.row_label else "";
    }

    pub fn description(self: *const Variant, choice_index: u8) []const u8 {
        return if (self.optionAt(choice_index)) |found| found.description else "";
    }

    pub fn cancelChoice(self: *const Variant) ?u8 {
        for (self.options, 0..) |candidate, index| {
            if (candidate.choice == .cancel) return @intCast(index);
        }
        return null;
    }

    pub fn modeForChoice(self: *const Variant, choice_index: u8) ?PermissionMode {
        const found = self.optionAt(choice_index) orelse return null;
        return found.choice.mode();
    }

    pub fn declines(self: *const Variant, choice_index: u8) bool {
        const found = self.optionAt(choice_index) orelse return true;
        return found.choice == .cancel;
    }
};

const goal_manual_options = [_]Option{
    option(1, .never_ask, "Switch to Never Ask and start", "Best if you want fx to keep working while you are away. Tools are approved automatically and questions are skipped; only plans in Plan mode wait for your review."),
    option(2, .ask_when_needed, "Switch to Ask When Needed and start", "Tools are approved automatically. fx may still ask you questions."),
    option(3, .always_ask, "Start in Always Ask", "Keep approvals on. fx will ask before risky actions, so the goal may stop and wait for you."),
    option(4, .cancel, "Do not start", "Return to the input box with your goal command."),
};

const goal_yolo_options = [_]Option{
    option(1, .never_ask, "Switch to Never Ask and start", "Best if you want fx to keep working while you are away. Tools are approved automatically and questions are skipped; only plans in Plan mode wait for your review."),
    option(2, .ask_when_needed, "Keep Ask When Needed and start", "Tools stay approved automatically. fx may still ask you questions."),
    option(3, .cancel, "Do not start", "Return to the input box with your goal command."),
};

const swarm_manual_options = [_]Option{
    option(1, .never_ask, "Switch to Never Ask and start", "Best for swarm tasks. Tools are approved automatically and questions are skipped; only plans in Plan mode wait for your review."),
    option(2, .ask_when_needed, "Switch to Ask When Needed and start", "Tools are approved automatically. fx may still ask you questions."),
    option(3, .always_ask, "Start in Always Ask", "Keep approvals on. fx may stop and wait for you during the swarm task."),
};

const goal_manual_extra_rows = [_][]const u8{goal_manual_options[3].row_label};

pub const goal_manual: Variant = .{
    .kind = .goal,
    .title = "Start a goal with approvals on?",
    .notice_lines = .{
        "Always Ask mode asks you before fx runs commands, edits files, or takes other risky actions, and is not suitable for unattended goal work.",
        "You can go back without losing your command.",
    },
    .options = &goal_manual_options,
    .extra_row_labels = &goal_manual_extra_rows,
};

pub const goal_yolo: Variant = .{
    .kind = .goal,
    .title = "Start a goal in Ask When Needed mode?",
    .notice_lines = .{
        "Ask When Needed mode approves tools automatically, but can still stop for questions.",
        "Switch to Never Ask if you want questions skipped during goal work.",
    },
    .options = &goal_yolo_options,
    .extra_row_labels = &.{},
};

pub const swarm_manual: Variant = .{
    .kind = .swarm,
    .title = "Start a swarm task with approvals on?",
    .notice_lines = .{
        "Always Ask mode asks you before fx runs commands, edits files, or takes other risky actions, and can block swarm work while agents are running.",
        "You can go back without losing your command.",
    },
    .options = &swarm_manual_options,
    .extra_row_labels = &.{},
};

const variants = [_]*const Variant{ &goal_manual, &goal_yolo, &swarm_manual };

pub fn variantFor(kind: Kind, mode: PermissionMode) ?*const Variant {
    return switch (kind) {
        .goal => switch (mode) {
            .ask => &goal_manual,
            .yolo => &goal_yolo,
            .auto, .dontAsk => null,
        },
        .swarm => switch (mode) {
            .ask => &swarm_manual,
            .yolo, .auto, .dontAsk => null,
        },
    };
}

pub fn variantForTitle(title: []const u8) ?*const Variant {
    for (variants) |variant| {
        if (std.mem.eql(u8, variant.title, title)) return variant;
    }
    return null;
}

pub fn modeForResponse(
    variant: *const Variant,
    decision: types.ToolPermissionDecision,
    selected_option: ?u8,
) ?PermissionMode {
    if (decision.isDenied()) return null;
    return variant.modeForChoice(selected_option orelse return null);
}

test "a start prompt response names a mode only when a start row was approved" {
    try std.testing.expectEqual(@as(?PermissionMode, .auto), modeForResponse(&goal_manual, .once, 0));
    try std.testing.expectEqual(@as(?PermissionMode, .yolo), modeForResponse(&goal_manual, .once, 1));
    try std.testing.expectEqual(@as(?PermissionMode, .ask), modeForResponse(&goal_manual, .once, 2));
    try std.testing.expectEqual(@as(?PermissionMode, null), modeForResponse(&goal_manual, .deny, 0));
    try std.testing.expectEqual(@as(?PermissionMode, null), modeForResponse(&goal_manual, .once, null));
    try std.testing.expectEqual(@as(?PermissionMode, null), modeForResponse(&goal_yolo, .deny, 2));
    try std.testing.expectEqual(@as(?PermissionMode, .auto), modeForResponse(&swarm_manual, .once, 0));
}

test "the goal start prompt offers four options in Always Ask and three in Ask When Needed" {
    const manual = variantFor(.goal, .ask).?;
    try std.testing.expectEqualStrings("Start a goal with approvals on?", manual.title);
    try std.testing.expectEqual(@as(usize, 4), manual.options.len);
    try std.testing.expectEqualStrings("1. Switch to Never Ask and start", manual.rowLabel(0));
    try std.testing.expectEqualStrings("2. Switch to Ask When Needed and start", manual.rowLabel(1));
    try std.testing.expectEqualStrings("3. Start in Always Ask", manual.rowLabel(2));
    try std.testing.expectEqualStrings("4. Do not start", manual.rowLabel(3));
    try std.testing.expectEqual(@as(usize, 1), manual.extra_row_labels.len);
    try std.testing.expectEqualStrings("4. Do not start", manual.extra_row_labels[0]);
    try std.testing.expectEqual(@as(?u8, 3), manual.cancelChoice());

    const yolo = variantFor(.goal, .yolo).?;
    try std.testing.expectEqualStrings("Start a goal in Ask When Needed mode?", yolo.title);
    try std.testing.expectEqual(@as(usize, 3), yolo.options.len);
    try std.testing.expectEqualStrings("2. Keep Ask When Needed and start", yolo.rowLabel(1));
    try std.testing.expectEqualStrings("3. Do not start", yolo.rowLabel(2));
    try std.testing.expectEqual(@as(usize, 0), yolo.extra_row_labels.len);
    try std.testing.expectEqual(@as(?u8, 2), yolo.cancelChoice());
}

test "the goal start prompt is skipped in Never Ask and dontAsk and the swarm prompt shows only in Always Ask" {
    try std.testing.expect(variantFor(.goal, .auto) == null);
    try std.testing.expect(variantFor(.goal, .dontAsk) == null);
    try std.testing.expect(variantFor(.swarm, .yolo) == null);
    try std.testing.expect(variantFor(.swarm, .auto) == null);

    const swarm = variantFor(.swarm, .ask).?;
    try std.testing.expectEqualStrings("Start a swarm task with approvals on?", swarm.title);
    try std.testing.expectEqual(@as(usize, 3), swarm.options.len);
    try std.testing.expectEqual(@as(?u8, null), swarm.cancelChoice());
    try std.testing.expectEqualStrings("3. Start in Always Ask", swarm.rowLabel(2));
}

test "start prompt choices map to the permission mode they start under" {
    const manual = &goal_manual;
    try std.testing.expectEqual(@as(?PermissionMode, .auto), manual.modeForChoice(0));
    try std.testing.expectEqual(@as(?PermissionMode, .yolo), manual.modeForChoice(1));
    try std.testing.expectEqual(@as(?PermissionMode, .ask), manual.modeForChoice(2));
    try std.testing.expectEqual(@as(?PermissionMode, null), manual.modeForChoice(3));
    try std.testing.expect(manual.declines(3));
    try std.testing.expect(!manual.declines(2));
    try std.testing.expect(manual.declines(9));

    try std.testing.expectEqual(@as(?PermissionMode, .yolo), goal_yolo.modeForChoice(1));
    try std.testing.expect(goal_yolo.declines(2));
}

test "a start prompt is recognised by its title and nothing else" {
    try std.testing.expect(variantForTitle("Start a goal with approvals on?").? == &goal_manual);
    try std.testing.expect(variantForTitle("Start a goal in Ask When Needed mode?").? == &goal_yolo);
    try std.testing.expect(variantForTitle("Start a swarm task with approvals on?").? == &swarm_manual);
    try std.testing.expect(variantForTitle("Approve the plan and leave plan mode?") == null);
}

test "start prompt text names fx and never the reference product" {
    for (variants) |variant| {
        for (variant.notice_lines) |line| try std.testing.expect(std.mem.find(u8, line, "Kimi") == null);
        for (variant.options) |candidate| {
            try std.testing.expect(std.mem.find(u8, candidate.description, "Kimi") == null);
        }
    }
}
