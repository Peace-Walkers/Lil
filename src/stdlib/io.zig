const std = @import("std");
const value_mod = @import("../compiler/value.zig");
const VM = @import("../runtime/vm.zig").VM;
const ObjString = value_mod.ObjString;
const VariantObj = value_mod.VariantObj;
const TableObj = value_mod.TableObj;
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

pub fn read(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    const v: *VM = @ptrCast(@alignCast(vm));

    if (arg_count != 1 or args[0] != .Object or args[0].Object.obj_type != .String) {
        std.debug.print("Runtime Error: io::read expects exactly 1 string argument (the path).\n", .{});
        return .Null;
    }

    const path_obj: *ObjString = @fieldParentPtr("obj", args[0].Object);
    const path = path_obj.chars;

    var content_slice: []u8 = undefined;
    if (std.mem.eql(u8, path, "stdin")) {
        var temp_buf: [1024]u8 = undefined;
        const read_len = v.io.in.readSliceShort(&temp_buf) catch 0;
        content_slice = v.allocator.alloc(u8, read_len) catch unreachable;
        @memcpy(content_slice, temp_buf[0..read_len]);
    } else {
        content_slice = std.Io.Dir.cwd().readFileAlloc(v.io.system, path, v.allocator, .unlimited) catch {
            std.debug.print("Runtime Error: Failed to read file.\n", .{});
            return .Null;
        };
    }

    const content_str = v.allocator.create(ObjString) catch unreachable;
    content_str.* = .{
        .obj = .{ .obj_type = .String, .next = null },
        .chars = content_slice,
    };

    var result_table = v.allocator.create(TableObj) catch unreachable;
    result_table.* = .{
        .obj = .{ .obj_type = .Table, .next = null },
        .fields = std.StringHashMap(Value).init(v.allocator),
        .elements = .empty,
    };

    result_table.fields.put("content", .{ .Object = &content_str.obj }) catch unreachable;
    result_table.fields.put("cursor", .{ .Number = @intCast(content_slice.len) }) catch unreachable;

    return .{ .Object = &result_table.obj };
}
