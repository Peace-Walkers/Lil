const std = @import("std");
const value_mod = @import("../../compiler/value.zig");
const VM = @import("../../runtime/vm.zig").VM;
const Value = value_mod.Value;
const TableObj = value_mod.TableObj;

pub fn push(vm: *anyopaque, arg_count: u8, args: [*]Value) !Value {
    if (args[0] != .Object or args[0].Object.obj_type != .String) {
        //TODO: return a error
        return .Null;
    }

    const string = args[0].Object.toString();

    if (arg_count == 2) {
        const v: *VM = @ptrCast(@alignCast(vm));

        var new_string = try v.allocator.alloc(u8, string.chars.len + 1);
        @memcpy(new_string[0..string.chars.len], string.chars);
        new_string[string.chars.len] = args[1].Object.toString().chars[0];
        v.allocator.free(string.chars);
        string.chars = new_string;
    }

    return args[0];
}

pub fn to_num(vm: *anyopaque, arg_count: u8, args: [*]Value) !Value {
    _ = arg_count;
    const v: *VM = @ptrCast(@alignCast(vm));
    const string = args[0].Object.toString();

    const num = std.fmt.parseInt(i64, string.chars, 10) catch |err| {
        return v.createResultErr(@errorName(err));
    };

    return .{ .Number = num };
}

pub fn len(vm: *anyopaque, arg_count: u8, args: [*]Value) !Value {
    _ = vm;
    _ = arg_count;

    if (args[0] != .Object or args[0].Object.obj_type != .String) {
        //TODO: return a error
        return .Null;
    }

    const string = args[0].Object.toString();

    return .{ .Number = @intCast(string.chars.len) };
}

pub fn split(vm: *anyopaque, arg_count: u8, args: [*]Value) !Value {
    if (args[0] != .Object or args[0].Object.obj_type != .String) {
        //TODO: return a error
        return .Null;
    }

    if (arg_count != 2) {
        return .Null;
    }

    if (args[1] != .Object or args[1].Object.obj_type != .String) {
        return .Null;
    }

    const v: *VM = @ptrCast(@alignCast(vm));
    const sep = args[1].Object.toString();
    const string = args[0].Object.toString();

    var splitted = std.mem.splitSequence(u8, string.chars, sep.chars);

    const table = try v.createTable();

    while (splitted.next()) |slice| {
        const duped_part = try v.allocator.dupe(u8, slice);
        const new_str = try v.createString(duped_part);

        const val = Value{ .Object = &new_str.obj };
        val.retain();
        try table.elements.append(v.allocator, val);
    }

    return .{ .Object = &table.obj };
}
