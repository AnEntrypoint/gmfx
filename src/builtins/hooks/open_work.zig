const std = @import("std");
const hooks = @import("../../core/hooks/hooks.zig");
const io_mod = @import("../../core/shared/io.zig");

pub const handler_name = "fx.todo.open_work";

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = @FieldType(App, "main_agent");

        pub fn configure(app: *App) !void {
            try app.lifecycle_runtime.registerStop(.{
                .name = handler_name,
                .ctx = app,
                .run = stop,
                .applies = applies,
            });
        }

        fn applies(ctx: *anyopaque, invocation: hooks.Invocation) bool {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (invocation.scope.kind == .subagent) return false;
            const turn_id = invocation.turn_id orelse return false;
            const agent = agentInTurn(app, turn_id) orelse return false;
            const todo = &agent.session.agent.todo;
            return todo.seeded and agent.open_work_reminder.owedFor(turn_id, todo.items);
        }

        fn stop(ctx: *anyopaque, input: hooks.StopInput) hooks.HandlerError!hooks.StopAction {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (!input.can_continue or input.invocation.scope.kind == .subagent) return .allow;
            const turn_id = input.invocation.turn_id orelse return .allow;
            const agent = agentInTurn(app, turn_id) orelse return .allow;
            const todo = &agent.session.agent.todo;
            if (!todo.seeded) return .allow;
            const text = agent.open_work_reminder.forTurn(turn_id, todo.items) orelse return .allow;
            return .{ .continue_once = text };
        }

        fn agentInTurn(app: *App, turn_id: u64) ?*AppAgent {
            if (app.main_agent.worker.activeTurnId() == turn_id) return &app.main_agent;
            app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
            defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
            for (app.child_agents.items) |child| {
                if (child.agent.role == .subagent) continue;
                if (child.agent.worker.activeTurnId() == turn_id) return &child.agent;
            }
            return null;
        }
    };
}
