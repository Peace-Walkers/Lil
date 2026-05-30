const std = @import("std");
const chunk_mod = @import("../compiler/chunk.zig");
const OpCode = chunk_mod.OpCode;
const Chunk = chunk_mod.Chunk;
const value_mod = @import("../compiler/value.zig");
const Value = value_mod.Value;
const ObjString = value_mod.ObjString;
const FunctionObj = value_mod.FunctionObj;
const TableObj = value_mod.TableObj;
const VariantObj = value_mod.VariantObj;
const debug = @import("../compiler/debug.zig");

pub const VmError = error{
    CompileError,
    RuntimeError,
};

const CallFrame = struct {
    function: *FunctionObj,
    /// instruction pointer
    ip: usize,
    /// stack index for local variables
    slot_offset: usize,
};

pub const VM = struct {
    const Self = @This();

    // Call Stack
    frames: [64]CallFrame,
    frame_count: usize,

    // Value Stack
    stack: [256]Value,
    stack_top: usize,

    globals: std.StringHashMap(Value),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .frames = undefined,
            .stack = undefined,
            .stack_top = 0,
            .globals = std.StringHashMap(Value).init(allocator),
            .allocator = allocator,
            .frame_count = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.globals.deinit();
    }

    fn currentFrame(self: *Self) *CallFrame {
        return &self.frames[self.frame_count - 1];
    }

    fn push(self: *Self, value: Value) void {
        self.stack[self.stack_top] = value;
        self.stack_top += 1;
    }

    fn pop(self: *Self) Value {
        self.stack_top -= 1;
        return self.stack[self.stack_top];
    }

    fn readByte(self: *Self) u8 {
        var frame = self.currentFrame();
        const byte = frame.function.chunk.code.items[frame.ip];
        frame.ip += 1;
        return byte;
    }

    fn readShort(self: *Self) u16 {
        var frame = self.currentFrame();
        frame.ip += 2;
        return (@as(u16, frame.function.chunk.code.items[frame.ip - 2]) << 8) | frame.function.chunk.code.items[frame.ip - 1];
    }

    fn peek(self: *Self, distance: usize) Value {
        return self.stack[self.stack_top - 1 - distance];
    }

    fn valuesEquals(self: *Self, a: Value, b: Value) !bool {
        if (@intFromEnum(a) != @intFromEnum(b)) {
            std.debug.print("Runtime Error: Invalid comparison between incompatible types '{s}' and '{s}'\n", .{ @tagName(a), @tagName(b) });
            return error.RuntimeError;
        }

        switch (a) {
            .Number => |n| {
                return n == b.Number;
            },
            .Boolean => |bo| {
                return bo == b.Boolean;
            },
            .Null => {
                return true;
            },
            .Object => |a_obj| {
                const b_obj = b.Object;

                if (a_obj.obj_type != b_obj.obj_type) {
                    std.debug.print("Runtime Error: Invalid comparison between incompatible types '{s}' and '{s}'\n", .{ @tagName(a_obj.obj_type), @tagName(b.Object.obj_type) });
                    return error.RuntimeError;
                }

                switch (a_obj.obj_type) {
                    .String => {
                        const string_a_obj: *ObjString = @fieldParentPtr("obj", a_obj);
                        const str_a = string_a_obj.chars;

                        const string_b_obj: *ObjString = @fieldParentPtr("obj", b_obj);
                        const str_b = string_b_obj.chars;

                        return std.mem.eql(u8, str_a, str_b);
                    },
                    .Table => {
                        const table_a_obj: *TableObj = @fieldParentPtr("obj", a_obj);

                        const table_b_obj: *TableObj = @fieldParentPtr("obj", b_obj);

                        if (table_a_obj.elements.items.len != table_b_obj.elements.items.len)
                            return false;

                        for (table_a_obj.elements.items, 0..) |elem_a, i| {
                            const elem_b = table_b_obj.elements.items[i];
                            if (!try self.valuesEquals(elem_a, elem_b))
                                return false;
                        }

                        if (table_a_obj.fields.count() != table_b_obj.fields.count()) return false;

                        var it_a = table_a_obj.fields.iterator();

                        while (it_a.next()) |a_field| {
                            if (table_b_obj.fields.get(a_field.key_ptr.*)) |b_value| {
                                const a_value = a_field.value_ptr.*;
                                if (!try self.valuesEquals(a_value, b_value))
                                    return false;
                            } else {
                                return false;
                            }
                        }
                        return true;
                    },
                    .Variant => {
                        const var_a_obj: *VariantObj = @fieldParentPtr("obj", a_obj);
                        const var_b_obj: *VariantObj = @fieldParentPtr("obj", b_obj);

                        const a_namespace = var_a_obj.namespace;
                        const b_namespace = var_b_obj.namespace;

                        const a_name = var_a_obj.variant_name;
                        const b_name = var_b_obj.variant_name;

                        const a_payload = var_a_obj.payload;
                        const b_payload = var_b_obj.payload;

                        if (a_namespace) |a_n| {
                            if (b_namespace) |b_n| {
                                if (!std.mem.eql(u8, a_n.chars, b_n.chars))
                                    return false;
                            } else {
                                return false;
                            }
                        } else if (b_namespace) |_| {
                            return false;
                        }

                        if (!std.mem.eql(u8, a_name.chars, b_name.chars))
                            return false;

                        if (a_payload.len != b_payload.len)
                            return false;

                        for (a_payload, 0..) |a_value, i| {
                            const b_value = b_payload[i];
                            if (!try self.valuesEquals(a_value, b_value))
                                return false;
                        }

                        return true;
                    },
                    .Function => {
                        const fn_a_obj: *FunctionObj = @fieldParentPtr("obj", a_obj);
                        const fn_b_obj: *FunctionObj = @fieldParentPtr("obj", b_obj);

                        return fn_a_obj == fn_b_obj;
                    },
                }
            },
        }
    }

    fn isFalsey(value: Value) bool {
        switch (value) {
            .Number => |n| return n == 0,
            .Boolean => |b| return !b,
            else => return false,
        }
    }

    fn readConstant(self: *Self) Value {
        const frame = self.currentFrame();
        return frame.function.chunk.constants.items[self.readByte()];
    }

    pub fn interpret(self: *Self, function: *FunctionObj) !void {
        self.push(.{ .Object = &function.obj });

        self.frames[0] = .{
            .function = function,
            .ip = 0,
            .slot_offset = 0,
        };
        self.frame_count = 1;
        return self.run();
    }

    fn run(self: *Self) !void {
        while (true) {
            var frame = self.currentFrame();

            _ = debug.disassembleInstruction(&frame.function.chunk, frame.ip) catch 0;

            const instruction = self.readByte();
            const op: OpCode = @enumFromInt(instruction);

            switch (op) {
                .OP_CONSTANT => {
                    const constant = self.readConstant();
                    self.push(constant);
                },
                .OP_DEFINE_GLOBAL => {
                    const name_val = self.readConstant();
                    const name_obj: *ObjString = @fieldParentPtr("obj", name_val.Object);
                    const name = name_obj.chars;

                    const value = self.pop();
                    try self.globals.put(name, value);
                },
                .OP_SET_GLOBAL => {
                    const name_val = self.readConstant();
                    const name_obj: *ObjString = @fieldParentPtr("obj", name_val.Object);
                    const name = name_obj.chars;

                    if (!self.globals.contains(name)) {
                        std.debug.print("Error undefined variable: '{s}'.\n", .{name});
                        return error.RuntimeError;
                    }

                    const value = self.peek(0);
                    try self.globals.put(name, value);
                },
                .OP_GET_GLOBAL => {
                    const name_val = self.readConstant();
                    const name_obj: *ObjString = @fieldParentPtr("obj", name_val.Object);
                    const name = name_obj.chars;

                    if (self.globals.get(name)) |value| {
                        self.push(value);
                    } else {
                        std.debug.print("Runtime Error: undefined var: {s}\n", .{name});
                        return error.RuntimeError;
                    }
                },
                .OP_BUILD_TABLE => {
                    const array_count = self.readByte();
                    const dict_count = self.readByte();

                    var table_obj = try self.allocator.create(TableObj);
                    table_obj.* = .{
                        .obj = .{ .obj_type = .Table, .next = null },
                        .fields = std.StringHashMap(Value).init(self.allocator),
                        .elements = .empty,
                    };

                    var i: usize = 0;
                    while (i < dict_count) : (i += 1) {
                        const value = self.pop();
                        const key_val = self.pop();

                        const key_obj: *ObjString = @fieldParentPtr("obj", key_val.Object);
                        try table_obj.fields.put(key_obj.chars, value);
                    }

                    try table_obj.elements.resize(self.allocator, array_count);
                    var j: usize = array_count;
                    while (j > 0) {
                        j -= 1;
                        table_obj.elements.items[j] = self.pop();
                    }

                    self.push(.{ .Object = &table_obj.obj });
                },
                .OP_GET_PROPERTY => {
                    const name_val = self.readConstant();
                    const name_obj: *ObjString = @fieldParentPtr("obj", name_val.Object);
                    const property_name = name_obj.chars;

                    const instance_val = self.pop();

                    if (instance_val != .Object or instance_val.Object.obj_type != .Table) {
                        std.debug.print("Runtime Error: Only tables have properties.\n", .{});
                        return error.RuntimeError;
                    }

                    const table: *TableObj = @fieldParentPtr("obj", instance_val.Object);

                    if (table.fields.get(property_name)) |value| {
                        self.push(value);
                    } else {
                        std.debug.print("Runtime Error: Undefined property '{s}'.\n", .{property_name});
                        return error.RuntimeError;
                    }
                },
                .OP_INVOKE => {
                    const methode_name_val = self.readConstant();
                    const methode_name_obj: *ObjString = @fieldParentPtr("obj", methode_name_val.Object);
                    const method_name = methode_name_obj.chars;

                    const arg_count = self.readByte();

                    const receiver = self.peek(arg_count);

                    if (receiver != .Object or receiver.Object.obj_type != .Table) {
                        std.debug.print("Runtime Error: Only tables have methods.\n", .{});
                        return error.Runtime;
                    }

                    const table: *TableObj = @fieldParentPtr("obj", receiver.Object);

                    if (table.fields.get(method_name)) |methode_val| {
                        if (methode_val != .Object or methode_val.Object.obj_type != .Function) {
                            std.debug.print("Runtime Error: Property '{s}' is not a function\n", .{method_name});
                            return error.RuntimeError;
                        }

                        const func: *FunctionObj = @fieldParentPtr("obj", methode_val.Object);

                        if (arg_count + 1 != func.arity) {
                            std.debug.print("Runtime Error: Expected {d} args but got {d}", .{ func.arity, arg_count + 1 });
                            return error.RuntimeError;
                        }

                        if (self.frame_count == 64) {
                            std.debug.print("Runtime Error: Stack Overflow\n", .{});
                            return error.RuntimeError;
                        }

                        var i: usize = 0;
                        while (i <= arg_count) : (i += 1) {
                            self.stack[self.stack_top - i] = self.stack[self.stack_top - i - 1];
                        }

                        self.stack[self.stack_top - arg_count - 1] = .{ .Object = &func.obj };
                        self.stack_top += 1;

                        self.frames[self.frame_count] = .{
                            .function = func,
                            .ip = 0,
                            .slot_offset = self.stack_top - 2,
                        };
                        self.frame_count += 1;
                    } else {
                        std.debug.print("Runtime Error: Undefined property '{s}'.\n", .{method_name});
                        return error.RuntimeError;
                    }
                },
                .OP_ADD => {
                    const b = self.pop();
                    const a = self.pop();

                    const result = a.Number + b.Number;
                    self.push(.{ .Number = result });
                },
                .OP_SUBTRACT => {
                    const b = self.pop();
                    const a = self.pop();

                    const result = a.Number - b.Number;
                    self.push(.{ .Number = result });
                },
                .OP_EQUAL => {
                    const a = self.pop();
                    const b = self.pop();

                    self.push(.{ .Boolean = try self.valuesEquals(a, b) });
                },
                .OP_RETURN => {
                    const result = self.pop();
                    self.frame_count -= 1;

                    if (self.frame_count == 0) {
                        std.debug.print("====FINAL MEMORY STATE====\n", .{});
                        var it = self.globals.iterator();
                        while (it.next()) |entry| {
                            std.debug.print("{s} = ", .{entry.key_ptr.*});
                            entry.value_ptr.*.print();
                            std.debug.print("\n", .{});
                        }
                        return;
                    }

                    self.stack_top = self.frames[self.frame_count].slot_offset;
                    self.push(result);
                },
                .OP_POP => {
                    _ = self.pop();
                },
                .OP_GET_LOCAL => {
                    const slot = self.readByte();
                    self.push(self.stack[frame.slot_offset + slot]);
                },
                .OP_SET_LOCAL => {
                    const slot = self.readByte();
                    self.stack[frame.slot_offset + slot] = self.peek(0);
                },
                .OP_JUMP_IF_FALSE => {
                    const offset = self.readShort();
                    if (isFalsey(self.peek(0))) {
                        frame.ip += offset;
                    }
                },
                .OP_LOOP => {
                    const offset = self.readShort();
                    frame.ip -= offset;
                },
                .OP_JUMP => {
                    const offset = self.readShort();
                    frame.ip += offset;
                },
                .OP_CALL => {
                    const arg_count = self.readByte();
                    const callee = self.peek(arg_count);

                    if (callee != .Object or callee.Object.obj_type != .Function) {
                        std.debug.print("Runtime Error: Can only call function.\n", .{});
                        return error.RuntimeError;
                    }
                    const func: *FunctionObj = @fieldParentPtr("obj", callee.Object);

                    if (arg_count != func.arity) {
                        std.debug.print("Runtime Error: expected {d} arg(s) receive {d}\n", .{ func.arity, arg_count });
                        return error.RuntimeError;
                    }

                    if (self.frame_count == 64) {
                        std.debug.print("Runtime Error: Stack Overflow\n", .{});
                        return error.RuntimeError;
                    }

                    self.frames[self.frame_count] = .{
                        .function = func,
                        .ip = 0,
                        .slot_offset = self.stack_top - arg_count - 1,
                    };
                    self.frame_count += 1;
                },
                .OP_GET_INDEX => {
                    const index_val = self.pop();
                    const object_val = self.pop();

                    if (index_val != .Number) {
                        std.debug.print("Runtime Error: Index must be a number.\n", .{});
                        return error.RuntimeError;
                    }

                    const index: usize = @intCast(index_val.Number);

                    if (object_val == .Object and object_val.Object.obj_type == .Table) {
                        const table: *TableObj = @fieldParentPtr("obj", object_val.Object);

                        if (index >= table.elements.items.len) {
                            std.debug.print("Runtime Error: Array index out of bounds.\n", .{});
                            return error.RuntimeError;
                        }
                        self.push(table.elements.items[index]);
                    } else if (object_val == .Object and object_val.Object.obj_type == .String) {
                        const string: *ObjString = @fieldParentPtr("obj", object_val.Object);

                        if (index >= string.chars.len) {
                            std.debug.print("Runtime Error: String index out of bounds.\n", .{});
                            return error.RuntimeError;
                        }

                        const char = string.chars[index];

                        var char_slice = try self.allocator.alloc(u8, 1);
                        char_slice[0] = char;

                        var new_str = try self.allocator.create(ObjString);
                        new_str.* = .{
                            .obj = .{ .obj_type = .String, .next = null },
                            .chars = char_slice,
                        };

                        self.push(.{ .Object = &new_str.obj });
                    } else {
                        std.debug.print("Runtime Error: Can only index arrays and strings.\n", .{});
                        return error.RuntimeError;
                    }
                },
                .OP_MATCH_TEST => {
                    const has_ns = self.readByte();
                    const ns_idx = self.readByte();
                    const name_idx = self.readByte();
                    const expected_bindings = self.readByte();

                    const target = self.peek(0);

                    const name_val = frame.function.chunk.constants.items[name_idx];
                    const name_str_obj: *ObjString = @fieldParentPtr("obj", name_val.Object);
                    const name_str = name_str_obj.chars;

                    if (std.mem.eql(u8, name_str, "_")) {
                        self.push(.{ .Boolean = true });
                        continue;
                    }

                    if (target != .Object or target.Object.obj_type != .Variant) {
                        self.push(.{ .Boolean = false });
                        continue;
                    }

                    const variant_obj: *VariantObj = @fieldParentPtr("obj", target.Object);
                    if (!std.mem.eql(u8, variant_obj.variant_name.chars, name_str)) {
                        self.push(.{ .Boolean = false });
                        continue;
                    }

                    if (has_ns == 1) {
                        const ns_val = frame.function.chunk.constants.items[ns_idx];
                        const ns_str_obj: *ObjString = @fieldParentPtr("obj", ns_val.Object);
                        const ns_str = ns_str_obj.chars;

                        if (variant_obj.namespace) |v_ns| {
                            if (!std.mem.eql(u8, v_ns.chars, ns_str)) {
                                self.push(.{ .Boolean = false });
                                continue;
                            }
                        } else {
                            self.push(.{ .Boolean = false });
                            continue;
                        }
                    }

                    if (variant_obj.payload.len != expected_bindings) {
                        self.push(.{ .Boolean = false });
                        continue;
                    }

                    self.push(.{ .Boolean = true });
                },
                .OP_MATCH_BIND => {
                    const binding_count = self.readByte();

                    if (binding_count > 0) {
                        const target = self.peek(0);
                        const variant_obj: *VariantObj = @fieldParentPtr("obj", target.Object);

                        for (variant_obj.payload) |val| {
                            self.push(val);
                        }
                    }
                },
                .OP_BUILD_VARIANT => {
                    const ns_val = self.readConstant();
                    const name_val = self.readConstant();
                    const arg_count = self.readByte();

                    const ns_obj: *ObjString = @fieldParentPtr("obj", ns_val.Object);
                    const name_obj: *ObjString = @fieldParentPtr("obj", name_val.Object);

                    var payload = try self.allocator.alloc(Value, arg_count);

                    var i: usize = arg_count;
                    while (i > 0) {
                        i -= 1;
                        payload[i] = self.pop();
                    }

                    const variant_obj = try self.allocator.create(VariantObj);
                    variant_obj.* = .{
                        .obj = .{ .obj_type = .Variant, .next = null },
                        .namespace = ns_obj,
                        .variant_name = name_obj,
                        .payload = payload,
                    };

                    self.push(.{ .Object = &variant_obj.obj });
                },
                else => {
                    std.debug.print("Error: Invalid OpCode.\n", .{});
                    return error.RuntimeError;
                },
            }
        }
    }
};
