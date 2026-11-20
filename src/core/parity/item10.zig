const std = @import("std");

const agents_reason = "ListAgents is a host session tool; no ListAgents surface exists in src/, so the binary cannot list peer sessions";
const findings_reason = "ReportFindings is a host code-review tool; no ReportFindings surface exists in src/, so the binary cannot report typed findings";
const message_reason = "SendMessage is a host cross-session tool; no SendMessage surface exists in src/, so the binary cannot message a peer session";
const loop_reason = "the step, batch and finish habits of a run are native defaults: the working loop in src/builtins/system_prompt.md with Bash, TaskOutput, TaskStop, TaskList, WaitFor, TodoList, Agent, AgentSwarm and read_tool_result in src/builtins/tools.zig";

pub fn json(alloc: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    _ = args;
    return std.fmt.allocPrint(alloc, "{{\"item\":10,\"kind\":\"host-tools\",\"offline\":true,\"status\":\"open\",\"ok\":false,\"entries\":[{{\"name\":\"ListAgents\",\"status\":\"open\",\"reason\":\"{s}\"}},{{\"name\":\"ReportFindings\",\"status\":\"open\",\"reason\":\"{s}\"}},{{\"name\":\"SendMessage\",\"status\":\"open\",\"reason\":\"{s}\"}},{{\"name\":\"working-loop\",\"status\":\"present\",\"reason\":\"{s}\"}}]}}", .{ agents_reason, findings_reason, message_reason, loop_reason });
}
