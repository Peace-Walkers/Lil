const std = @import("std");
const value_mod = @import("../compiler/value.zig");
const VM = @import("../runtime/vm.zig").VM;
const Value = value_mod.Value;

fn isResultErr(res: Value) bool {
    if (res != .Object)
        return false;
    if (res.Object.obj_type == .Variant) {
        const obj = res.Object.toVariant();
        if (std.mem.eql(u8, obj.variant_name.chars, "Err"))
            return true;
    }

    return false;
}

pub fn fetch(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    const v: *VM = @ptrCast(@alignCast(vm));

    if (arg_count != 1 or args[0] != .Object or args[0].Object.obj_type != .String) {
        return v.createResultErr("net::fetch expect exactly 1 string argument (URL)") catch unreachable;
    }

    const url_str = args[0].Object.toString().chars;

    var client = std.http.Client{ .io = v.io.system, .allocator = v.allocator };
    defer client.deinit();

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(v.allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(v.allocator, &buf);

    const res = client.fetch(.{
        .location = .{ .url = url_str },
        .method = .GET,
        .response_writer = &writer.writer,
    }) catch {
        return v.createResultErr("HTTP request failed (network error).") catch unreachable;
    };

    writer.writer.flush() catch {};

    var raw_body_slice = writer.writer.toArrayList();
    const body_slice = raw_body_slice.toOwnedSlice(v.allocator) catch unreachable;
    const body_str = v.createString(body_slice) catch unreachable;

    var result_table = v.createTable() catch unreachable;

    result_table.fields.put("status", .{ .Number = @intFromEnum(res.status) }) catch unreachable;
    result_table.fields.put("body", .{ .Object = &body_str.obj }) catch unreachable;

    return v.createResultOk(.{ .Object = &result_table.obj }) catch unreachable;
}

///This function take a Request Description Table:
///{
///     url: String,
///     header: String,
///     body: String,
///     method: String,
///     ContentLength: Number,
///}
pub fn request(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    const v: *VM = @ptrCast(@alignCast(vm));

    if (arg_count != 1 or args[0] != .Object or args[0].Object.obj_type != .Table) {
        return v.createResultErr("net::request expect exactly 1 argument (Request Description Table)") catch unreachable;
    }

    const request_description_table = args[0].Object.toTable();

    //TODO: check the presence & the type of the value in the table fields
    const url = request_description_table.fields.get("url");
}
