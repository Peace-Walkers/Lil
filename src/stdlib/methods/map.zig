const VM = @import("../../runtime/vm.zig").VM;
const value_mod = @import("../../compiler/value.zig");
const Value = value_mod.Value;

pub fn new(vm: *anyopaque, arg_count: u8, args: [*]Value) !Value {
    _ = arg_count;
    _ = args;
    const v: *VM = @ptrCast(@alignCast(vm));

    const map = try v.createMap();
    return .{ .Object = &map.obj };
}

pub fn put(vm: *anyopaque, arg_count: u8, args: [*]Value) !Value {
    const v: *VM = @ptrCast(@alignCast(vm));
    if (args[0] != .Object or args[0].Object.obj_type != .Map) {
        return v.createResultErr("'put' method is dedicated to Map.");
    }

    if (arg_count != 3) return v.createResultErr("Excepected 3 args");

    const map = args[0].Object.toMap();
    const key = args[1];
    const value = args[2];

    if (map.hashmap.fetchRemove(key)) |old_entry| {
        old_entry.key.release(v.allocator, v.io.system);
        old_entry.value.release(v.allocator, v.io.system);
    }

    try map.hashmap.put(key, value);

    args[0].retain();

    return args[0];
}

pub fn get(vm: *anyopaque, arg_count: u8, args: [*]Value) !Value {
    const v: *VM = @ptrCast(@alignCast(vm));
    if (args[0] != .Object or args[0].Object.obj_type != .Map) {
        return v.createResultErr("'put' method is dedicated to Map.");
    }

    const map = args[0].Object.toMap();

    if (arg_count == 2) {
        const key = args[1];
        if (map.hashmap.get(key)) |value| {
            value.retain();
            return value;
        }
    }
    return .Null;
}
