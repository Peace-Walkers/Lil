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

    pub fn print(self: Value, indent: usize) void {
        switch (self) {
            .Null => std.debug.print("null", .{}),
            .Boolean => |b| std.debug.print("{any}", .{b}),
            .Number => |n| std.debug.print("{d}", .{n}),
            .Object => |obj| obj.print(indent),
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

    pub fn toString(self: *Obj) *ObjString {
        return @fieldParentPtr("obj", self);
    }

    pub fn toTable(self: *Obj) *TableObj {
        return @fieldParentPtr("obj", self);
    }

    pub fn toFunction(self: *Obj) *FunctionObj {
        return @fieldParentPtr("obj", self);
    }

    pub fn toVariant(self: *Obj) *VariantObj {
        return @fieldParentPtr("obj", self);
    }

    pub fn toNative(self: *Obj) *ObjNative {
        return @fieldParentPtr("obj", self);
    }

    pub fn print(self: *Obj, indent: usize) void {
        switch (self.obj_type) {
            .String => {
                const string_obj = self.toString();
                std.debug.print("\"{s}\"", .{string_obj.chars});
            },
            .Table => {
                const table_obj = self.toTable();

                if (table_obj.elements.items.len == 0 and table_obj.fields.count() == 0) {
                    std.debug.print("Table {{}}", .{});
                    return;
                }

                std.debug.print("Table {{\n", .{});

                if (table_obj.elements.items.len > 0) {
                    printIndent(indent + 1);
                    std.debug.print("elements: [ ", .{});
                    for (table_obj.elements.items, 0..) |elem, i| {
                        elem.print(indent + 1);
                        if (i != table_obj.elements.items.len - 1) {
                            std.debug.print(", ", .{});
                        }
                    }
                    std.debug.print(" ],\n", .{});
                }

                var it = table_obj.fields.iterator();
                while (it.next()) |field| {
                    printIndent(indent + 1);
                    std.debug.print("{s}: ", .{field.key_ptr.*});
                    field.value_ptr.*.print(indent + 1);
                    std.debug.print(",\n", .{});
                }

                printIndent(indent);
                std.debug.print("}}", .{});
            },
            .Function => std.debug.print("<Fn>", .{}),
            .Variant => std.debug.print("<Variant>", .{}),
            .Native => {
                const native_obj = self.toNative();
                std.debug.print("<NativeFn {s}>", .{native_obj.name});
            },
        }
    }
};

fn printIndent(indent: usize) void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        std.debug.print("    ", .{}); // 4 espaces par niveau
    }
}

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

pub const NativeFn = *const fn (vm: *anyopaque, arg_count: u8, args: [*]Value) Value;

pub const ObjNative = struct {
    obj: Obj,
    function: NativeFn,
    name: []const u8,
};
