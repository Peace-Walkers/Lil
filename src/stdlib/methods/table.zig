const std = @import("std");
const value_mod = @import("../../compiler/value.zig");
const VM = @import("../../runtime/vm.zig").VM;
const Value = value_mod.Value;
const TableObj = value_mod.TableObj;

pub fn push(vm: *anyopaque, arg_count: u8, args: [*]Value) !Value {
    if (args[0] != .Object or args[0].Object.obj_type != .Table) {
        //TODO: return a error
        return .Null;
    }

    const table = args[0].Object.toTable();

    if (arg_count == 2) {
        const v: *VM = @ptrCast(@alignCast(vm));
        args[1].retain();
        try table.elements.append(v.allocator, args[1]);
    }

    args[0].retain();
    return args[0];
}

pub fn pop(vm: *anyopaque, arg_count: u8, args: [*]Value) !Value {
    _ = vm;
    if (args[0] != .Object or args[0].Object.obj_type != .Table) {
        //TODO: return a error
        return .Null;
    }

    const table = args[0].Object.toTable();

    if (arg_count == 1) {
        if (table.elements.pop()) |result| {
            return result;
        }
    }

    return .Null;
}

pub fn map(vm: *anyopaque, arg_count: u8, args: [*]Value) !Value {
    const v: *VM = @ptrCast(@alignCast(vm));

    if (arg_count < 2 or args[0] != .Object or args[0].Object.obj_type != .Table) {
        //TODO: return a error
        return .Null;
    }

    const table = args[0].Object.toTable();
    const lambda = args[1];

    const new_table = try v.createTable();

    for (table.elements.items) |elem| {
        lambda.retain();
        elem.retain();
        const result = v.executeLambda(lambda, elem) catch {
            new_table.obj.release(v.allocator, v.io.system);
            return .Null;
        };

        try new_table.elements.append(v.allocator, result);
    }

    return .{ .Object = &new_table.obj };
}

pub fn foreach(vm: *anyopaque, arg_count: u8, args: [*]Value) !Value {
    const v: *VM = @ptrCast(@alignCast(vm));

    if (arg_count < 2 or args[0] != .Object or args[0].Object.obj_type != .Table) {
        //TODO: return a error
        return .Null;
    }

    const table = args[0].Object.toTable();
    const lambda = args[1];

    for (table.elements.items) |elem| {
        lambda.retain();
        elem.retain();
        const value = try v.executeLambda(lambda, elem);
        value.release(v.allocator, v.io.system);
    }

    args[0].retain();
    return args[0];
}

pub fn filter(vm: *anyopaque, arg_count: u8, args: [*]Value) !Value {
    const v: *VM = @ptrCast(@alignCast(vm));

    if (arg_count < 2 or args[0] != .Object or args[0].Object.obj_type != .Table) {
        //TODO: return a error
        return .Null;
    }

    const table = args[0].Object.toTable();
    const lambda = args[1];

    const new_table = try v.createTable();

    for (table.elements.items) |elem| {
        lambda.retain();
        elem.retain();
        const condition_res = v.executeLambda(lambda, elem) catch {
            new_table.obj.release(v.allocator, v.io.system);
            return .Null;
        };

        if (!VM.isFalsey(condition_res)) {
            elem.retain();
            try new_table.elements.append(v.allocator, elem);
        }

        condition_res.release(v.allocator, v.io.system);
    }
    return .{ .Object = &new_table.obj };
}

pub fn len(vm: *anyopaque, arg_count: u8, args: [*]Value) !Value {
    _ = vm;

    if (arg_count > 1 or args[0] != .Object or args[0].Object.obj_type != .Table) {
        //TODO: return a error
        return .Null;
    }

    const table = args[0].Object.toTable();

    return .{ .Number = @intCast(table.elements.items.len) };
}
