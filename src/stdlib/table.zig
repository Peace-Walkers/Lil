const std = @import("std");
const value_mod = @import("../compiler/value.zig");
const VM = @import("../runtime/vm.zig").VM;
const Value = value_mod.Value;
const TableObj = value_mod.TableObj;

pub fn push(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    if (args[0] != .Object or args[0].Object.obj_type != .Table) {
        //TODO: return a error
        return .Null;
    }

    const table: *TableObj = @fieldParentPtr("obj", args[0].Object);

    if (arg_count == 2) {
        const v: *VM = @ptrCast(@alignCast(vm));
        table.elements.append(v.allocator, args[1]) catch unreachable;
    }

    return args[0];
}

pub fn map(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    const v: *VM = @ptrCast(@alignCast(vm));

    if (arg_count < 2 or args[0] != .Object or args[0].Object.obj_type != .Table) {
        //TODO: return a error
        return .Null;
    }

    const table: *TableObj = @fieldParentPtr("obj", args[0].Object);
    const lambda = args[1];

    const new_table = v.allocator.create(TableObj) catch unreachable;
    new_table.* = .{
        .obj = .{ .obj_type = .Table, .next = null },
        .fields = std.StringHashMap(Value).init(v.allocator),
        .elements = .empty,
    };

    for (table.elements.items) |elem| {
        const result = v.executeLambda(lambda, elem) catch {
            return .Null;
        };

        new_table.elements.append(v.allocator, result) catch unreachable;
    }

    return .{ .Object = &new_table.obj };
}

pub fn filter(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    const v: *VM = @ptrCast(@alignCast(vm));

    if (arg_count < 2 or args[0] != .Object or args[0].Object.obj_type != .Table) {
        //TODO: return a error
        return .Null;
    }

    const table: *TableObj = @fieldParentPtr("obj", args[0].Object);
    const lambda = args[1];

    const new_table = v.allocator.create(TableObj) catch unreachable;
    new_table.* = .{
        .obj = .{ .obj_type = .Table, .next = null },
        .fields = std.StringHashMap(Value).init(v.allocator),
        .elements = .empty,
    };

    for (table.elements.items) |elem| {
        const condition_res = v.executeLambda(lambda, elem) catch {
            return .Null;
        };

        if (!VM.isFalsey(condition_res)) {
            new_table.elements.append(v.allocator, elem) catch unreachable;
        }
    }
    return .{ .Object = &new_table.obj };
}

pub fn len(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    _ = vm;

    if (arg_count > 1 or args[0] != .Object or args[0].Object.obj_type != .Table) {
        //TODO: return a error
        return .Null;
    }

    const table: *TableObj = @fieldParentPtr("obj", args[0].Object);

    return .{ .Number = @intCast(table.elements.items.len) };
}
