const std = @import("std");
const execute = @import("execute.zig");

const Allocator = std.mem.Allocator;

pub const ParseError = error{
    OutOfMemory,
    InvalidArguments,
    MissingAction,
    UnknownAction,
    MissingField,
    UnknownField,
};

pub const Request = struct {
    arena: std.heap.ArenaAllocator,
    action: execute.Action,
    target_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    params_json: []const u8 = "{}",

    pub fn deinit(self: *Request) void {
        self.arena.deinit();
    }

    pub fn parse(alloc: Allocator, args_json: []const u8) ParseError!Request {
        var request = Request{
            .arena = std.heap.ArenaAllocator.init(alloc),
            .action = undefined,
        };
        errdefer request.arena.deinit();
        const scratch = request.arena.allocator();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, scratch, args_json, .{}) catch return error.InvalidArguments;
        const object = switch (parsed) {
            .object => |object| object,
            else => return error.InvalidArguments,
        };
        var fields = object.iterator();
        while (fields.next()) |field| {
            if (!isKnownField(field.key_ptr.*)) return error.UnknownField;
        }
        request.action = std.meta.stringToEnum(execute.Action, try stringField(object, "action")) orelse return error.UnknownAction;
        try request.collectFields(object);
        return request;
    }

    fn collectFields(self: *Request, object: std.json.ObjectMap) ParseError!void {
        const owned = self.arena.allocator();
        switch (self.action) {
            .targets => {},
            .open => {
                const url = try stringField(object, "url");
                self.params_json = try std.json.Stringify.valueAlloc(owned, .{ .url = url }, .{});
            },
            .attach, .close => self.target_id = try dupeField(owned, object, "target_id"),
            .evaluate => {
                self.session_id = try dupeField(owned, object, "session_id");
                const expression = try stringField(object, "expression");
                self.params_json = try std.json.Stringify.valueAlloc(owned, .{ .expression = expression, .returnByValue = true }, .{});
                self.target_id = try optionalField(owned, object, "target_id");
            },
        }
    }

    pub fn command(self: *const Request, run_id: []const u8, request_id: []const u8) execute.Command {
        return .{
            .run_id = run_id,
            .request_id = request_id,
            .action = self.action,
            .target_id = self.target_id,
            .session_id = self.session_id,
            .params_json = self.params_json,
        };
    }
};

pub fn failureMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "browser ran out of memory",
        error.InvalidArguments => "browser arguments must be a JSON object with string fields",
        error.MissingAction => "browser requires field action",
        error.UnknownAction => "browser action must be one of targets, open, attach, evaluate, close",
        error.MissingField => "browser action is missing a required field: url for open, target_id for attach and close, session_id and expression for evaluate",
        error.UnknownField => "browser accepts only the fields action, url, target_id, session_id and expression",
    };
}

fn isKnownField(name: []const u8) bool {
    const known = [_][]const u8{ "action", "url", "target_id", "session_id", "expression" };
    for (known) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ParseError![]const u8 {
    const value = object.get(name) orelse return missingError(name);
    return switch (value) {
        .string => |text| text,
        else => error.InvalidArguments,
    };
}

fn missingError(name: []const u8) ParseError {
    return if (std.mem.eql(u8, name, "action")) error.MissingAction else error.MissingField;
}

fn dupeField(alloc: Allocator, object: std.json.ObjectMap, name: []const u8) ParseError![]const u8 {
    return alloc.dupe(u8, try stringField(object, name));
}

fn optionalField(alloc: Allocator, object: std.json.ObjectMap, name: []const u8) ParseError!?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| try alloc.dupe(u8, text),
        else => error.InvalidArguments,
    };
}

test "native_browser request parses each action and rejects bad fields" {
    const alloc = std.testing.allocator;

    var targets = try Request.parse(alloc, "{\"action\":\"targets\"}");
    defer targets.deinit();
    try std.testing.expectEqual(execute.Action.targets, targets.action);

    var evaluate = try Request.parse(alloc, "{\"action\":\"evaluate\",\"session_id\":\"S-1\",\"expression\":\"document.title\"}");
    defer evaluate.deinit();
    try std.testing.expectEqualStrings("S-1", evaluate.session_id.?);
    try std.testing.expectEqualStrings("{\"expression\":\"document.title\",\"returnByValue\":true}", evaluate.params_json);

    try std.testing.expectError(error.MissingField, Request.parse(alloc, "{\"action\":\"evaluate\",\"session_id\":\"S-1\"}"));
    try std.testing.expectError(error.MissingField, Request.parse(alloc, "{\"action\":\"close\"}"));
    try std.testing.expectError(error.UnknownAction, Request.parse(alloc, "{\"action\":\"click\"}"));
    try std.testing.expectError(error.MissingAction, Request.parse(alloc, "{\"url\":\"about:blank\"}"));
    try std.testing.expectError(error.UnknownField, Request.parse(alloc, "{\"action\":\"targets\",\"cwd\":\"/tmp\"}"));
    try std.testing.expectError(error.InvalidArguments, Request.parse(alloc, "[]"));
}
