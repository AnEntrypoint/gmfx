const std = @import("std");
const execute = @import("execute.zig");
const orchestrator = @import("orchestrator.zig");

pub const Fake = struct {
    alloc: std.mem.Allocator,
    sent: std.ArrayList([]u8) = .empty,
    observed: ?*const orchestrator.Orchestrator = null,
    observed_status: ?orchestrator.BrowserStatus = null,
    error_on: ?[]const u8 = null,
    drop_on: ?[]const u8 = null,

    pub fn deinit(self: *Fake) void {
        for (self.sent.items) |request| self.alloc.free(request);
        self.sent.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn transport(self: *Fake) execute.Transport {
        return .{ .context = self, .send_fn = send };
    }

    fn send(context: *anyopaque, reply_alloc: std.mem.Allocator, request_json: []const u8) anyerror![]u8 {
        const self: *Fake = @ptrCast(@alignCast(context));
        try self.sent.append(self.alloc, try self.alloc.dupe(u8, request_json));
        if (self.observed) |orch| self.observed_status = orch.browserStatus();
        var parsed = try std.json.parseFromSlice(std.json.Value, reply_alloc, request_json, .{});
        defer parsed.deinit();
        const id = parsed.value.object.get("id").?.string;
        const method = parsed.value.object.get("method").?.string;
        if (self.drop_on) |dropped| {
            if (std.mem.eql(u8, dropped, method)) return error.ConnectionClosed;
        }
        if (self.error_on) |failing| {
            if (std.mem.eql(u8, failing, method)) {
                return std.fmt.allocPrint(reply_alloc, "{{\"id\":\"{s}\",\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}", .{id});
            }
        }
        const result = if (std.mem.eql(u8, method, "Target.getTargets"))
            "{\"targetInfos\":[{\"type\":\"page\"},{\"type\":\"page\"},{\"type\":\"service_worker\"}]}"
        else if (std.mem.eql(u8, method, "Target.attachToTarget"))
            "{\"sessionId\":\"S-1\"}"
        else
            "{}";
        return std.fmt.allocPrint(reply_alloc, "{{\"id\":\"{s}\",\"result\":{s}}}", .{ id, result });
    }
};
