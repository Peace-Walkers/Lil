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
///     type: Variant,   # Filetype::File, Filetype::Directory, Filetype::SymLink, or Filetype::Unknown
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

    const path_obj: *ObjString = @fieldParentPtr("obj", args[0].Object);
    const path = path_obj.chars;

    const file_stat = std.Io.Dir.cwd().statFile(v.io.system, path, .{ .follow_symlinks = true }) catch {
        return .Null;
    };

    var stat_table = v.allocator.create(TableObj) catch unreachable;
    stat_table.* = .{
        .obj = .{ .obj_type = .Table, .next = null },
        .fields = std.StringHashMap(Value).init(v.allocator),
        .elements = .empty,
    };

    stat_table.fields.put("size", .{ .Number = @intCast(file_stat.size) }) catch unreachable;
    stat_table.fields.put("mtime", .{ .Number = @intCast(file_stat.mtime.toMilliseconds()) }) catch unreachable;
    if (file_stat.atime) |atime| {
        stat_table.fields.put("atime", .{ .Number = @intCast(atime.toMilliseconds()) }) catch unreachable;
    }
    stat_table.fields.put("ctime", .{ .Number = @intCast(file_stat.ctime.toMilliseconds()) }) catch unreachable;
    stat_table.fields.put("inode", .{ .Number = @intCast(file_stat.inode) }) catch unreachable;
    stat_table.fields.put("mode", .{ .Number = @intCast(@intFromEnum(file_stat.permissions)) }) catch unreachable;

    const ns_str = v.allocator.create(ObjString) catch unreachable;
    ns_str.* = .{ .obj = .{ .obj_type = .String, .next = null }, .chars = "Filetype" };

    const kind_str: []const u8 = switch (file_stat.kind) {
        .file => "File",
        .directory => "Directory",
        .sym_link => "SymLink",
        else => "Unknown",
    };

    const name_str = v.allocator.create(ObjString) catch unreachable;
    name_str.* = .{ .obj = .{ .obj_type = .String, .next = null }, .chars = kind_str };

    const kind_var = v.allocator.create(VariantObj) catch unreachable;
    kind_var.* = .{
        .obj = .{ .obj_type = .Variant, .next = null },
        .namespace = ns_str,
        .variant_name = name_str,
        .payload = &.{},
    };

    stat_table.fields.put("type", .{ .Object = &kind_var.obj }) catch unreachable;

    return .{ .Object = &stat_table.obj };
}
