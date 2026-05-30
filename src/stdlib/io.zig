const std = @import("std");
const value_mod = @import("../compiler/value.zig");
const Value = value_mod.Value;

pub fn print(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    _ = vm;
    if (arg_count == 0) {
        std.debug.print("\n", .{});
        return .Null;
    }

    args[0].print();
    std.debug.print("\n", .{});
    return .Null;
}
