const std = @import("std");
const value_mod = @import("../compiler/value.zig");
const Value = value_mod.Value;
const ObjString = value_mod.ObjString;
const TableObj = value_mod.TableObj;
const VariantObj = value_mod.VariantObj;

const VM = @import("../runtime/vm.zig").VM;

/// This function takes a file path in parameter and returns its metadata.
/// If the file does not exist, it returns Null.
///
/// Returns a table:
/// {
///     size: Number,    # Size of the file in bytes
///     kind: Variant,   # Filetype::File, Filetype::Directory, Filetype::SymLink, or Filetype::Unknown
///     mtime: Number,   # Last modification time (nanoseconds)
///     atime: Number,   # Last access time (nanoseconds)
///     ctime: Number,   # Creation/Status change time (nanoseconds)
///     inode: Number,   # File system inode number
///     mode: Number     # POSIX permissions mode (e.g., 33188 for typical files)
/// }
pub fn stat(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    const v: *VM = @ptrCast(@alignCast(vm));

    if (arg_count != 1 or args[0] != .Object or args[0].Object.obj_type != .String) {
        std.debug.print("Runtime Error: fs::stat expects exactly 1 string argument (the path).\n", .{});
        return .Null;
    }

    const path_obj = args[0].Object.toString();
    const path = path_obj.chars;

    const file_stat = std.Io.Dir.cwd().statFile(v.io.system, path, .{ .follow_symlinks = true }) catch {
        return .Null;
    };

    var stat_table = v.createTable() catch unreachable;

    stat_table.fields.put("size", .{ .Number = @intCast(file_stat.size) }) catch unreachable;
    stat_table.fields.put("mtime", .{ .Number = @intCast(file_stat.mtime.toMilliseconds()) }) catch unreachable;
    if (file_stat.atime) |atime| {
        stat_table.fields.put("atime", .{ .Number = @intCast(atime.toMilliseconds()) }) catch unreachable;
    }
    stat_table.fields.put("ctime", .{ .Number = @intCast(file_stat.ctime.toMilliseconds()) }) catch unreachable;
    stat_table.fields.put("inode", .{ .Number = @intCast(file_stat.inode) }) catch unreachable;
    stat_table.fields.put("mode", .{ .Number = @intCast(@intFromEnum(file_stat.permissions)) }) catch unreachable;

    const ns_str = v.createString("FileType") catch unreachable;

    const kind_str: []const u8 = switch (file_stat.kind) {
        .file => "File",
        .directory => "Dir",
        .sym_link => "Sym",
        else => "Unknown",
    };

    const name_str = v.createString(kind_str) catch unreachable;

    const kind_var = v.createVariant(ns_str, name_str, &.{}) catch unreachable;

    stat_table.fields.put("kind", .{ .Object = &kind_var.obj }) catch unreachable;

    return .{ .Object = &stat_table.obj };
}
