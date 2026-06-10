const std = @import("std");
const value_mod = @import("../../compiler/value.zig");
const VM = @import("../../runtime/vm.zig").VM;
const Value = value_mod.Value;
const TableObj = value_mod.TableObj;

pub fn unwrap(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    _ = vm;
    _ = arg_count;

    if (args[0] != .Object or args[0].Object.obj_type != .Variant) {
        //TODO: return a error
        return .Null;
    }

    const variant = args[0].Object.toVariant();

    if (std.mem.eql(u8, variant.variant_name.chars, "Ok")) {
        return variant.payload[0];
    } else {
        const error_msg = variant.payload[0].Object.toString().chars;
        std.debug.print("Runtime Error: called `unwrap()` on an `Err` value: {s}\n", .{error_msg});
        return .Null;
    }
}
