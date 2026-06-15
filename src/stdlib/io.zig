const std = @import("std");
const value_mod = @import("../compiler/value.zig");
const VM = @import("../runtime/vm.zig").VM;
const ObjString = value_mod.ObjString;
const VariantObj = value_mod.VariantObj;
const TableObj = value_mod.TableObj;
const Value = value_mod.Value;

fn internalPrint(v: *VM, arg_count: u8, args: [*]Value, newline: bool) !Value {
    if (arg_count == 0) {
        std.debug.print("\n", .{});
        return .Null;
    }

    const val = args[0];

    if (val == .Object and val.Object.obj_type == .String) {
        const string_obj = val.Object.toString();

        var mark: std.ArrayList(usize) = .empty;
        defer mark.deinit(v.allocator);

        var i: usize = 0;
        while (i < string_obj.chars.len) : (i += 1) {
            if (string_obj.chars[i] == '{' and i + 1 < string_obj.chars.len) {
                if (string_obj.chars[i + 1] == '}') {
                    try mark.append(v.allocator, i);
                    i += 1;
                }
            }
        }

        if (mark.items.len != arg_count - 1)
            return .Null;

        if (mark.items.len != 0) {
            var last_m: usize = 0;
            for (mark.items, 0..) |m, c| {
                const start = if (last_m == 0) 0 else last_m + 2; // skip '{}'
                std.debug.print("{s}", .{string_obj.chars[start..m]});
                args[c + 1].print(0);
                last_m = m;
            }
        } else {
            val.print(0);
        }
    } else {
        args[0].print(0);
    }

    if (newline) std.debug.print("\n", .{});

    return .Null;
}

pub fn print(vm: *anyopaque, arg_count: u8, args: [*]Value) !Value {
    // _ = vm;
    const v: *VM = @ptrCast(@alignCast(vm));
    return internalPrint(v, arg_count, args, false);
}

pub fn println(vm: *anyopaque, arg_count: u8, args: [*]Value) !Value {
    const v: *VM = @ptrCast(@alignCast(vm));
    return internalPrint(v, arg_count, args, true);
}

pub fn read(vm: *anyopaque, arg_count: u8, args: [*]Value) !Value {
    const v: *VM = @ptrCast(@alignCast(vm));

    if (arg_count != 1 or args[0] != .Object or args[0].Object.obj_type != .String) {
        return v.createResultErr("io::read expect exactly 1 string argument (the path).");
    }

    const path_obj = args[0].Object.toString();
    const path = path_obj.chars;

    var content_slice: []u8 = undefined;
    if (std.mem.eql(u8, path, "stdin")) {
        var temp_buf: [1024]u8 = undefined;
        const read_len = v.io.in.readSliceShort(&temp_buf) catch 0;
        content_slice = try v.allocator.alloc(u8, read_len);
        @memcpy(content_slice, temp_buf[0..read_len]);
    } else {
        content_slice = std.Io.Dir.cwd().readFileAlloc(v.io.system, path, v.allocator, .unlimited) catch {
            return try v.createResultErr("Failed to read file.");
        };
    }

    const content_str = try v.createString(content_slice);

    var result_table = try v.createTable();

    try result_table.fields.put("content", .{ .Object = &content_str.obj });
    try result_table.fields.put("cursor", .{ .Number = @intCast(content_slice.len) });

    return v.createResultOk(.{ .Object = &result_table.obj });
}
