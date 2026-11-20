const std = @import("std");
const fake_transport = @import("fake_transport.zig");

pub const cdp = @import("cdp.zig");
pub const session = @import("session.zig");
pub const execute = @import("execute.zig");
pub const orchestrator = @import("orchestrator.zig");
pub const birdman = @import("birdman.zig");
pub const request = @import("request.zig");
pub const route = @import("route.zig");
pub const BrowserState = orchestrator.BrowserState;
pub const BrowserStatus = orchestrator.BrowserStatus;

test "native_browser front door runs a single targets step through the transport seam" {
    const alloc = std.testing.allocator;
    var orchestration = orchestrator.Orchestrator.init("front-door");
    defer orchestration.deinit(alloc);
    var fake = fake_transport.Fake{ .alloc = alloc };
    defer fake.deinit();
    const commands = [_]execute.Command{.{ .run_id = "list-tabs", .request_id = "fx-1", .action = .targets }};
    var out: [1]cdp.Response = undefined;
    const count = try orchestration.runSequence(alloc, fake.transport(), "list-tabs", &commands, &out);
    defer for (out[0..count]) |response| cdp.responseOwnedDeinit(alloc, response);
    try std.testing.expectEqual(BrowserState.idle, orchestration.browserStatus().state);
    try std.testing.expectEqual(@as(usize, 2), orchestration.browserStatus().tab_count);
    var bluf: [256]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, orchestration.bluf(&bluf), "fx run list-tabs · browser · done · tabs"));
}
