const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;

pub const ValueType = enum {
    Null,
    Boolean,
    Number,
    Object, // Heap object
};

pub const Value = union(ValueType) {
    Null: void,
    Boolean: bool,
    Number: i64,
    Object: *Obj,

    pub fn print(self: Value) void {
        switch (self) {
            .Null => std.debug.print("null", .{}),
            .Boolean => |b| std.debug.print("{any}", .{b}),
            .Number => |n| std.debug.print("{d}", .{n}),
            .Object => |obj| obj.print(),
        }
    }
};

pub const ObjType = enum {
    String,
    Table,
    Function,
    Variant,
    Native,
};

pub const Obj = struct {
    obj_type: ObjType,
    next: ?*Obj,

    pub fn print(self: *Obj) void {
        switch (self.obj_type) {
            .String => {
                const string_obj: *ObjString = @fieldParentPtr("obj", self);
                std.debug.print("\"{s}\"", .{string_obj.chars});
            },
            .Table => std.debug.print("<Table>", .{}),
            .Function => std.debug.print("<Fn>", .{}),
            .Variant => std.debug.print("<Variant>", .{}),
            .Native => {
                const native_obj: *ObjNative = @fieldParentPtr("obj", self);
                std.debug.print("<NativeFn {s}>", .{native_obj.name});
            },
        }
    }
};

pub const ObjString = struct {
    obj: Obj,
    chars: []const u8,
};

pub const TableObj = struct {
    obj: Obj,
    fields: std.StringHashMap(Value),
    elements: std.ArrayList(Value),
};

pub const FunctionObj = struct {
    obj: Obj,
    arity: usize,
    chunk: Chunk,
    name: ?*ObjString,
};

pub const VariantObj = struct {
    obj: Obj,
    namespace: ?*ObjString,
    variant_name: *ObjString,
    payload: []Value,
};

pub const NativeFn = *const fn (arg_count: u8, args: [*]Value) Value;

pub const ObjNative = struct {
    obj: Obj,
    function: NativeFn,
    name: []const u8,
};
