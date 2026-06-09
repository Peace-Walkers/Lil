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

    pub fn asString(self: Value) ?[]const u8 {
        if (self == .Object and self.Object.obj_type == .String)
            return self.Object.toString().chars;
        return null;
    }

    pub fn asNumber(self: Value) ?i64 {
        if (self == .Number) return self.Number;
        return null;
    }

    pub fn asTable(self: Value) ?*TableObj {
        if (self == .Object and self.Object.obj_type == .Table)
            return self.Object.toTable();
        return null;
    }

    pub fn asFunction(self: Value) ?*FunctionObj {
        if (self == .Object and self.Object.obj_type == .Function)
            return self.Object.toFunction();
        return null;
    }

    pub fn asVariant(self: Value) ?*VariantObj {
        if (self == .Object and self.Object.obj_type == .Variant)
            return self.Object.toVariant();
        return null;
    }

    pub fn asNative(self: Value) ?*NativeObj {
        if (self == .Object and self.Object.obj_type == .Native)
            return self.Object.toNative();
        return null;
    }

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
    Map,
};

pub const Obj = struct {
    obj_type: ObjType,
    next: ?*Obj,

    pub fn toString(self: *Obj) *StringObj {
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

    pub fn toNative(self: *Obj) *NativeObj {
        return @fieldParentPtr("obj", self);
    }

    pub fn toMap(self: *Obj) *MapObj {
        return @fieldParentPtr("obj", self);
    }

    pub fn print(self: *Obj, indent: usize) void {
        switch (self.obj_type) {
            .String => {
                const string_obj = self.toString();
                std.debug.print("{s}", .{string_obj.chars});
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
            .Map => {
                const map = self.toMap();
                std.debug.print("{s}:\n", .{map.name.chars});
                var it = map.hashmap.iterator();
                while (it.next()) |kv| {
                    std.debug.print("[", .{});
                    kv.key_ptr.print(indent + 1);
                    std.debug.print("] : ", .{});
                    kv.value_ptr.print(indent + 1);
                }
            },
        }
    }
};

fn printIndent(indent: usize) void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        std.debug.print("    ", .{});
    }
}

pub const StringObj = struct {
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
    name: ?*StringObj,
    can_fail: bool,
};

pub const VariantObj = struct {
    obj: Obj,
    namespace: ?*StringObj,
    variant_name: *StringObj,
    payload: []Value,
};

pub const NativeFn = *const fn (vm: *anyopaque, arg_count: u8, args: [*]Value) Value;

pub const NativeObj = struct {
    obj: Obj,
    function: NativeFn,
    name: []const u8,
};

pub const ValueContext = struct {
    pub fn hash(self: @This(), key: Value) u64 {
        _ = self;
        var hasher = std.hash.Fnv1a_64.init();

        switch (key) {
            .Null => hasher.update("null"),
            .Boolean => |b| hasher.update(if (b) "true" else "false"),
            .Number => |n| {
                const bytes = std.mem.asBytes(n);
                hasher.update(bytes);
            },
            .Object => |obj| {
                switch (obj.obj_type) {
                    .String => {
                        const str_obj = obj.toString();
                        hasher.update(str_obj.chars);
                    },
                    else => {
                        const ptr_val = @intFromPtr(obj);
                        const bytes = std.mem.asBytes(ptr_val);
                        hasher.update(bytes);
                    },
                }
            },
        }
        return hasher.final();
    }

    pub fn eql(self: @This(), a: Value, b: Value) bool {
        _ = self;
        if (@intFromEnum(a) != @intFromEnum(b)) return false;

        switch (a) {
            .Null => return true,
            .Boolean => |bo| return bo == b.Boolean,
            .Number => |n| return n == b.Number,
            .Object => |a_obj| {
                const b_obj = b.Object;
                if (a_obj.obj_type != b_obj.obj_type) return false;

                switch (a_obj.obj_type) {
                    .String => {
                        const str_a = a_obj.toString().chars;
                        const str_b = b_obj.toString().chars;
                        return std.mem.eql(u8, str_a, str_b);
                    },
                    else => {
                        return a_obj == b_obj;
                    },
                }
            },
        }
    }
};

pub const MapObj = struct {
    obj: Obj,
    name: *StringObj,
    hashmap: std.HashMap(Value, Value, ValueContext, 80),
};
