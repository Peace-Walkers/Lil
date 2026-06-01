const std = @import("std");
const value_mod = @import("../compiler/value.zig");
const VM = @import("../runtime/vm.zig").VM;
const Value = value_mod.Value;
const TableObj = value_mod.TableObj;

pub fn push(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    if (args[0] != .Object or args[0].Object.obj_type != .String) {
        //TODO: return a error
        return .Null;
    }

    const string = args[0].Object.toString();

    if (arg_count == 2) {
        const v: *VM = @ptrCast(@alignCast(vm));

        var new_string = v.allocator.alloc(u8, string.chars.len + 1) catch unreachable;
        @memcpy(new_string[0..string.chars.len], string.chars);
        new_string[string.chars.len] = args[1].Object.toString().chars[0];
        v.allocator.free(string.chars);
        string.chars = new_string;
    }

    return args[0];
}

pub fn len(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    _ = vm;
    _ = arg_count;

    if (args[0] != .Object or args[0].Object.obj_type != .String) {
        //TODO: return a error
        return .Null;
    }

    const string = args[0].Object.toString();

    return .{ .Number = @intCast(string.chars.len) };
}
