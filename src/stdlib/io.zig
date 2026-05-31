const std = @import("std");
const value_mod = @import("../compiler/value.zig");
const ObjString = value_mod.ObjString;
const Value = value_mod.Value;

pub fn print(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    _ = vm;
    if (arg_count == 0) {
        std.debug.print("\n", .{});
        return .Null;
    }

    const val = args[0];

    if (val == .Object and val.Object.obj_type == .String) {
        const string_obj: *ObjString = @fieldParentPtr("obj", val.Object);

        var i: usize = 0;
        while (i < string_obj.chars.len) : (i += 1) {
            if (string_obj.chars[i] == '\\' and i + 1 < string_obj.chars.len and string_obj.chars[i + 1] == 'n') {
                std.debug.print("\n", .{});
                i += 1;
            } else {
                std.debug.print("{c}", .{string_obj.chars[i]});
            }
        }
    } else {
        args[0].print(0);
    }
    return .Null;
}
