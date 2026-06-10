const VM = @import("../../runtime/vm.zig").VM;
const value_mod = @import("../../compiler/value.zig");
const Value = value_mod.Value;

pub fn put(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    const v: *VM = @ptrCast(@alignCast(vm));
    if (args[0] != .Object or args[0].Object.obj_type != .Map) {
        return v.createResultErr("'put' method is dedicated to Map.") catch unreachable;
    }

    const map = args[0].Object.toMap();

    if (arg_count == 3) {
        const key = args[1];
        const value = args[2];

        map.hashmap.put(key, value) catch unreachable;
    }

    return args[0];
}

pub fn get(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    const v: *VM = @ptrCast(@alignCast(vm));
    if (args[0] != .Object or args[0].Object.obj_type != .Map) {
        return v.createResultErr("'put' method is dedicated to Map.") catch unreachable;
    }

    const map = args[0].Object.toMap();

    if (arg_count == 2) {
        const key = args[1];
        if (map.hashmap.get(key)) |value| {
            return value;
        }
    }
    return .Null;
}
