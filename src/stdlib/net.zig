const std = @import("std");
const value_mod = @import("../compiler/value.zig");
const VM = @import("../runtime/vm.zig").VM;
const Value = value_mod.Value;

pub fn fetch(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    const v: *VM = @ptrCast(@alignCast(vm));

    if (arg_count != 1 or args[0] != .Objecti or args[0].Object.obj_type != .String) {
        return v.createResultErr("net::fetch expect exactly 1 string argument (URL)");
    }

    const url_str = args[0].Object.toString().chars;

    var client = std.http.Client{ .io = v.io.system, .allocator = v.allocator };
    defer client.deinit();

    var response_body: std.ArrayList(u8) = .empty;
    errdefer response_body.deinit(v.allocator);
    const writer = std.Io.Writer.

    const res = client.fetch(.{
        .location = .{ .url = url_str },
        .method = .GET,
        
    }) catch {
        return v.createResultErr("HTTP request failed (network error).") catch unreachable;
    };

}
