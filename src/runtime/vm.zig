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
const ObjNative = value_mod.ObjNative;
const NativeFn = value_mod.NativeFn;
const debug = @import("../compiler/debug.zig");

const stdlib = @import("../stdlib/stdlib.zig");

pub const VmError = error{
    CompileError,
    RuntimeError,
    SyntaxError,
};

const CallFrame = struct {
    function: *FunctionObj,
    /// instruction pointer
    ip: usize,
    /// stack index for local variables
    slot_offset: usize,
};

pub const VmIo = struct {
    system: std.Io,
    in: *std.Io.Reader,
    out: *std.Io.Writer,
};

pub const ResolveFn = *const fn (vm: *VM, module_name: []const u8) anyerror![]const u8;

pub const VM = struct {
    const Self = @This();

    // Call Stack
    frames: [64]CallFrame,
    frame_count: usize,

    // Value Stack
    stack: [256]Value,
    stack_top: usize,

    // Native registry
    table_methods: std.StringHashMap(NativeFn),
    string_methods: std.StringHashMap(NativeFn),
    result_methods: std.StringHashMap(NativeFn),

    import_resolver: ?ResolveFn,
    loaded_modules: std.StringHashMap(Value),

    globals: std.StringHashMap(Value),
    allocator: std.mem.Allocator,
    io: VmIo,

    halt_frame_count: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, io: VmIo) !Self {
        var vm = Self{
            .frames = undefined,
            .stack = undefined,
            .stack_top = 0,
            .globals = std.StringHashMap(Value).init(allocator),
            .allocator = allocator,
            .frame_count = 0,
            .string_methods = std.StringHashMap(NativeFn).init(allocator),
            .table_methods = std.StringHashMap(NativeFn).init(allocator),
            .result_methods = std.StringHashMap(NativeFn).init(allocator),
            .halt_frame_count = null,
            .io = io,
            .loaded_modules = std.StringHashMap(Value).init(allocator),
            .import_resolver = null,
        };

        try vm.table_methods.put("push", stdlib.table.push);
        try vm.table_methods.put("map", stdlib.table.map);
        try vm.table_methods.put("filter", stdlib.table.filter);
        try vm.table_methods.put("len", stdlib.table.len);
        try vm.table_methods.put("pop", stdlib.table.pop);

        try vm.string_methods.put("push", stdlib.string.push);
        try vm.string_methods.put("len", stdlib.string.len);
        try vm.string_methods.put("split", stdlib.string.split);

        try vm.result_methods.put("unwrap", stdlib.variant.unwrap);

        return vm;
    }

    pub fn eval(self: *Self, source: []const u8) !void {
        const lexer = @import("../compiler/lexer.zig");
        const parser = @import("../compiler/parser.zig");
        const compiler = @import("../compiler/compiler.zig");

        var scanner = lexer.Lexer.init(source);
        var p = parser.Parser.init(&scanner, self.allocator);
        const ast_root = try p.parse();

        if (p.had_error) return error.CompileError;

        var chunk = chunk_mod.Chunk.init(self.allocator);
        var comp = compiler.Compiler.init(self.allocator, &chunk);

        try comp.compile(ast_root);
        try chunk.write(@intFromEnum(chunk_mod.OpCode.OP_RETURN), 0);

        const script_function = try self.allocator.create(FunctionObj);
        script_function.* = .{
            .obj = .{ .obj_type = .Function, .next = null },
            .arity = 0,
            .chunk = chunk,
            .name = null,
            .can_fail = true,
        };

        try self.interpret(script_function);
    }

    pub fn setGlobal(self: *Self, name: []const u8, value: Value) !void {
        try self.globals.put(name, value);
    }

    pub fn createNative(self: *Self, name: []const u8, func: NativeFn) !Value {
        const native_obj = try self.allocator.create(ObjNative);
        native_obj.* = .{
            .obj = .{ .obj_type = .Native, .next = null },
            .function = func,
            .name = name,
        };
        return .{ .Object = &native_obj.obj };
    }

    pub fn bindNative(self: *Self, table: *TableObj, name: []const u8, func: NativeFn) !void {
        const native_val = try self.createNative(name, func);
        try table.fields.put(name, native_val);
    }

    pub fn evalModule(self: *Self, source: []const u8) !Value {
        const lexer = @import("../compiler/lexer.zig");
        const parser = @import("../compiler/parser.zig");
        const compiler = @import("../compiler/compiler.zig");

        var scanner = lexer.Lexer.init(source);
        var p = parser.Parser.init(&scanner, self.allocator);
        const ast_root = try p.parse();

        if (p.had_error) return error.CompileError;

        var chunk = chunk_mod.Chunk.init(self.allocator);
        var comp = compiler.Compiler.init(self.allocator, &chunk);
        try comp.compile(ast_root);
        try chunk.write(@intFromEnum(chunk_mod.OpCode.OP_RETURN), 0);

        const script_function = try self.allocator.create(FunctionObj);
        script_function.* = .{
            .obj = .{ .obj_type = .Function, .next = null },
            .arity = 0,
            .chunk = chunk,
            .name = null,
            .can_fail = true,
        };

        const old_globals = self.globals;

        self.globals = try old_globals.clone();

        try self.interpret(script_function);

        var module_table = try self.createTable();
        var it = self.globals.iterator();
        while (it.next()) |entry| {
            if (!old_globals.contains(entry.key_ptr.*)) {
                try module_table.fields.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        self.globals.deinit();
        self.globals = old_globals;

        return .{ .Object = &module_table.obj };
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

    pub fn createString(self: *Self, chars: []const u8) !*ObjString {
        const obj_str = try self.allocator.create(ObjString);
        obj_str.* = .{
            .obj = .{ .obj_type = .String, .next = null },
            .chars = chars,
        };
        return obj_str;
    }

    pub fn createTable(self: *Self) !*TableObj {
        const table_obj = try self.allocator.create(TableObj);
        table_obj.* = .{
            .obj = .{ .obj_type = .Table, .next = null },
            .fields = std.StringHashMap(Value).init(self.allocator),
            .elements = .empty,
        };
        return table_obj;
    }

    pub fn createVariant(self: *Self, namespace: *ObjString, name: *ObjString, payload: []Value) !*VariantObj {
        const variant_obj = try self.allocator.create(VariantObj);
        variant_obj.* = .{
            .obj = .{ .obj_type = .Variant, .next = null },
            .namespace = namespace,
            .variant_name = name,
            .payload = payload,
        };
        return variant_obj;
    }

    pub fn createResultOk(self: *Self, payload: Value) !Value {
        const ns_str = try self.createString("Result");
        const name_str = try self.createString("Ok");

        const payload_slice = try self.allocator.alloc(Value, 1);
        payload_slice[0] = payload;

        const variant_obj = try self.createVariant(ns_str, name_str, payload_slice);
        return .{ .Object = &variant_obj.obj };
    }

    pub fn createResultErr(self: *Self, error_msg: []const u8) !Value {
        const ns_str = try self.createString("Result");
        const name_str = try self.createString("Err");
        const err_str = try self.createString(error_msg);

        const payload_slice = try self.allocator.alloc(Value, 1);

        payload_slice[0] = .{ .Object = &err_str.obj };
        const variant_obj = try self.createVariant(ns_str, name_str, payload_slice);
        return .{ .Object = &variant_obj.obj };
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
                        const string_a_obj = a_obj.toString();
                        const str_a = string_a_obj.chars;

                        const string_b_obj = b_obj.toString();
                        const str_b = string_b_obj.chars;

                        return std.mem.eql(u8, str_a, str_b);
                    },
                    .Table => {
                        const table_a_obj = a_obj.toTable();

                        const table_b_obj = b_obj.toTable();

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
                        const var_a_obj = a_obj.toVariant();
                        const var_b_obj = b_obj.toVariant();

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
                        const fn_a_obj = a_obj.toFunction();
                        const fn_b_obj = b_obj.toFunction();

                        return fn_a_obj == fn_b_obj;
                    },
                    .Native => {
                        const native_obj_a = a_obj.toNative();
                        const native_obj_b = b_obj.toNative();

                        return native_obj_a.function == native_obj_b.function;
                    },
                }
            },
        }
    }

    pub fn executeLambda(self: *Self, lambda: Value, arg: Value) !Value {
        if (lambda != .Object or lambda.Object.obj_type != .Function) {
            std.debug.print("Runtime Error: Expected a function for lambda execution.\n", .{});
            return error.RuntimeError;
        }
        const func = lambda.Object.toFunction();

        const starting_frame_count = self.frame_count;

        if (self.frame_count == 64) {
            std.debug.print("Runtime Error: Stack Overflow\n", .{});
            return error.RuntimeError;
        }

        const base_stack_top = self.stack_top;

        self.stack[self.stack_top] = lambda;
        self.stack_top += 1;

        self.stack[self.stack_top] = arg;
        self.stack_top += 1;

        self.frames[self.frame_count] = .{
            .function = func,
            .ip = 0,
            .slot_offset = base_stack_top,
        };
        self.frame_count += 1;

        const previous_halt = self.halt_frame_count;
        self.halt_frame_count = starting_frame_count;

        try self.run();

        self.halt_frame_count = previous_halt;

        const lambda_result = self.stack[self.stack_top - 1];

        self.stack_top = base_stack_top;

        return lambda_result;
    }

    pub fn isFalsey(value: Value) bool {
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

    pub fn interpret(self: *Self, function: *FunctionObj) anyerror!void {
        self.push(.{ .Object = &function.obj });

        self.frames[0] = .{
            .function = function,
            .ip = 0,
            .slot_offset = self.stack_top - 1,
        };
        self.frame_count = 1;
        return self.run();
    }

    fn run(self: *Self) !void {
        while (true) {
            var frame = self.currentFrame();

            // _ = debug.disassembleInstruction(&frame.function.chunk, frame.ip) catch 0;

            const instruction = self.readByte();
            const op: OpCode = @enumFromInt(instruction);

            switch (op) {
                .OP_CONSTANT => {
                    const constant = self.readConstant();
                    self.push(constant);
                },
                .OP_DEFINE_GLOBAL => {
                    const name_val = self.readConstant();
                    const name_obj = name_val.Object.toString();
                    const name = name_obj.chars;

                    const value = self.pop();
                    try self.globals.put(name, value);
                },
                .OP_SET_GLOBAL => {
                    const name_val = self.readConstant();
                    const name_obj = name_val.Object.toString();
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
                    const name_obj = name_val.Object.toString();
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

                    var table_obj = try self.createTable();

                    var i: usize = 0;
                    while (i < dict_count) : (i += 1) {
                        const value = self.pop();
                        const key_val = self.pop();

                        const key_obj = key_val.Object.toString();
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
                .OP_IMPORT => {
                    const path_val = self.pop();
                    if (path_val != .Object or path_val.Object.obj_type != .String) {
                        std.debug.print("Runtime Error: Import path must be a string.\n", .{});
                        return error.RuntimeError;
                    }

                    const module_name = path_val.Object.toString().chars;

                    if (self.loaded_modules.get(module_name)) |module_val| {
                        self.push(module_val);
                        continue;
                    }

                    if (self.import_resolver == null) {
                        std.debug.print("Runtime Error: Import failed: no module solver registred.\n", .{});
                        return error.RuntimeError;
                    }

                    const source = self.import_resolver.?(self, module_name) catch {
                        std.debug.print("Runtime Error: Failed to load module '{s}'.\n", .{module_name});
                        return error.RuntimeError;
                    };

                    const module_val = try self.evalModule(source);

                    try self.loaded_modules.put(module_name, module_val);
                    self.push(module_val);
                },
                .OP_GET_PROPERTY => {
                    const name_val = self.readConstant();
                    const name_obj = name_val.Object.toString();
                    const property_name = name_obj.chars;

                    const instance_val = self.pop();

                    if (instance_val != .Object or instance_val.Object.obj_type != .Table) {
                        std.debug.print("Runtime Error: Only tables have properties.\n", .{});
                        return error.RuntimeError;
                    }

                    const table = instance_val.Object.toTable();

                    if (table.fields.get(property_name)) |value| {
                        self.push(value);
                    } else {
                        std.debug.print("Runtime Error: Undefined property '{s}'.\n", .{property_name});
                        return error.RuntimeError;
                    }
                },
                .OP_SET_PROPRETY => {
                    const name_val = self.readConstant();
                    const name_obj = name_val.Object.toString();
                    const property_name = name_obj.chars;

                    const value = self.pop();
                    const instance_val = self.pop();

                    if (instance_val != .Object or instance_val.Object.obj_type != .Table) {
                        std.debug.print("Runtime Error: Only tables have properties.\n", .{});
                        return error.RuntimeError;
                    }

                    const table = instance_val.Object.toTable();

                    try table.fields.put(property_name, value);

                    self.push(value);
                },
                .OP_INVOKE => {
                    const methode_name_val = self.readConstant();
                    const methode_name_obj = methode_name_val.Object.toString();
                    const method_name = methode_name_obj.chars;

                    const arg_count = self.readByte();
                    const receiver = self.peek(arg_count);

                    if (receiver != .Object) {
                        std.debug.print("Runtime Error: Only objects have methods.\n", .{});
                        return error.RuntimeError;
                    }

                    switch (receiver.Object.obj_type) {
                        .Table => {
                            const table = receiver.Object.toTable();

                            if (table.fields.get(method_name)) |methode_val| {
                                if (methode_val != .Object or methode_val.Object.obj_type != .Function) {
                                    std.debug.print("Runtime Error: Property '{s}' is not a function\n", .{method_name});
                                    return error.RuntimeError;
                                }

                                const func = methode_val.Object.toFunction();

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
                            } else if (self.table_methods.get(method_name)) |native_func| {
                                const total_args = arg_count + 1;
                                const args_slice = self.stack[self.stack_top - total_args .. self.stack_top];

                                const result = native_func(@ptrCast(self), total_args, args_slice.ptr);

                                self.stack_top -= total_args;
                                self.push(result);
                            } else {
                                std.debug.print("Runtime Error: Undefined property '{s}'.\n", .{method_name});
                                return error.RuntimeError;
                            }
                        },
                        .String => {
                            if (self.string_methods.get(method_name)) |native_func| {
                                const total_args = arg_count + 1;
                                const args_slice = self.stack[self.stack_top - total_args .. self.stack_top];

                                const result = native_func(@ptrCast(self), total_args, args_slice.ptr);

                                self.stack_top -= total_args;
                                self.push(result);
                            } else {
                                std.debug.print("Runtime Error: Undefined string method '{s}'.\n", .{method_name});
                                return error.RuntimeError;
                            }
                        },
                        .Variant => {
                            const variant = receiver.Object.toVariant();
                            if (variant.namespace) |namespace| {
                                if (std.mem.eql(u8, namespace.chars, "Result")) {
                                    if (self.result_methods.get(method_name)) |native_fn| {
                                        const total_args = arg_count + 1;
                                        const args_slice = self.stack[self.stack_top - total_args .. self.stack_top];
                                        const result = native_fn(@ptrCast(self), total_args, args_slice.ptr);
                                        self.stack_top -= total_args;
                                        self.push(result);
                                    } else {
                                        std.debug.print("Runtime Error: Undefined method '{s}' on Result variant.\n", .{method_name});
                                        return error.RuntimeError;
                                    }
                                }
                            } else {
                                if (variant.namespace) |namespace| {
                                    std.debug.print("Runtime Error: Variant '{s}' does not support methods.\n", .{namespace.chars});
                                } else {
                                    std.debug.print("Runtime Error: Variant '{s}' does not support methods.\n", .{variant.variant_name.chars});
                                }
                                return error.RuntimeError;
                            }
                        },
                        else => {
                            std.debug.print("Runtime Error: Type '{s}' does not support methods.\n", .{@tagName(receiver.Object.obj_type)});
                            return error.RuntimeError;
                        },
                    }
                },
                .OP_ADD => {
                    const b = self.pop();
                    const a = self.pop();

                    if (a != .Number or b != .Number) {
                        a.print(0);
                        b.print(0);
                        std.debug.print("Runtime Error: Operand must be numbers.\n", .{});
                        return error.RuntimeError;
                    }

                    const result = a.Number + b.Number;
                    self.push(.{ .Number = result });
                },
                .OP_SUBTRACT => {
                    const b = self.pop();
                    const a = self.pop();

                    const result = a.Number - b.Number;
                    self.push(.{ .Number = result });
                },
                .OP_MULTIPLY => {
                    const a = self.pop();
                    const b = self.pop();

                    if (a != .Number or b != .Number) {
                        std.debug.print("Runtime Error: Operand must be numbers.\n", .{});
                        return error.RuntimeError;
                    }

                    const result = a.Number * b.Number;
                    self.push(.{ .Number = result });
                },
                .OP_LESS => {
                    const b = self.pop();
                    const a = self.pop();

                    if (a != .Number or b != .Number) {
                        std.debug.print("Runtime Error: Operand must be numbers.\n", .{});
                        return error.RuntimeError;
                    }

                    self.push(.{ .Boolean = a.Number < b.Number });
                },
                .OP_GREATER => {
                    const b = self.pop();
                    const a = self.pop();

                    if (a != .Number or b != .Number) {
                        std.debug.print("Runtime Error: Operand must be numbers.\n", .{});
                        return error.RuntimeError;
                    }

                    self.push(.{ .Boolean = a.Number > b.Number });
                },
                .OP_EQUAL => {
                    const a = self.pop();
                    const b = self.pop();

                    self.push(.{ .Boolean = try self.valuesEquals(a, b) });
                },
                .OP_RETURN => {
                    const result = self.pop();
                    var final_result = result;
                    const current_frame = self.frames[self.frame_count - 1];

                    if (current_frame.function.can_fail) {
                        var is_already_result = false;

                        if (result == .Object and result.Object.obj_type == .Variant) {
                            const variant = result.Object.toVariant();
                            if (variant.namespace) |namespace| {
                                if (std.mem.eql(u8, namespace.chars, "Result")) {
                                    is_already_result = true;
                                }
                            }
                        }
                        if (!is_already_result) {
                            final_result = self.createResultOk(result) catch unreachable;
                        }
                    }

                    self.frame_count -= 1;

                    self.stack_top = self.frames[self.frame_count].slot_offset;
                    self.push(result);

                    if (self.halt_frame_count) |halt_target| {
                        if (self.frame_count == halt_target) return;
                    } else if (self.frame_count == 0) {
                        // std.debug.print("====FINAL MEMORY STATE====\n", .{});
                        // var it = self.globals.iterator();
                        // while (it.next()) |entry| {
                        //     std.debug.print("{s} = ", .{entry.key_ptr.*});
                        //     entry.value_ptr.*.print();
                        //     std.debug.print("\n", .{});
                        // }
                        return;
                    }

                    self.stack_top = self.frames[self.frame_count].slot_offset;
                    self.push(final_result);
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

                    if (callee != .Object) {
                        std.debug.print("Runtime Error: Can only call functions or native methods.\n", .{});
                        return error.RuntimeError;
                    }

                    switch (callee.Object.obj_type) {
                        .Function => {
                            const func = callee.Object.toFunction();

                            if (func.arity != 255 and arg_count != func.arity) {
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
                        .Native => {
                            const native_obj = callee.Object.toNative();
                            const args_slice = self.stack[self.stack_top - arg_count .. self.stack_top];
                            const result = native_obj.function(self, arg_count, args_slice.ptr);

                            self.stack_top -= (arg_count + 1);
                            self.push(result);
                        },
                        else => {
                            std.debug.print("Runtime Error: Object is not callable.\n", .{});
                            return error.RuntimeError;
                        },
                    }
                },
                .OP_TRY => {
                    const top_val = self.peek(0);

                    if (top_val != .Object or top_val.Object.obj_type != .Variant) {
                        std.debug.print("Runtime Error: '?' operator expects a Result variant.\n", .{});
                        return error.RuntimeError;
                    }

                    const variant = top_val.Object.toVariant();
                    if (variant.namespace) |namespace| {
                        if (!std.mem.eql(u8, namespace.chars, "Result")) {
                            std.debug.print("Runtime Error: '?' operator expects a Result variant.\n", .{});
                            return error.RuntimeError;
                        }
                    } else {
                        std.debug.print("Runtime Error: '?' operator expects a Result variant.\n", .{});
                        return error.RuntimeError;
                    }

                    if (std.mem.eql(u8, variant.variant_name.chars, "Ok")) {
                        _ = self.pop();
                        self.push(variant.payload[0]);
                    } else {
                        if (self.frame_count == 1) {
                            //INFO: main script case
                            const msg = variant.payload[0].Object.toString().chars;
                            std.debug.print("Unhandled error in main : {s}\n", .{msg});
                            return error.RuntimeError;
                        } else {
                            //INFO: inside a function case
                            const err_result = self.pop();

                            self.frame_count -= 1;
                            self.stack_top = self.frames[self.frame_count].slot_offset;
                            self.push(err_result);
                        }
                    }
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
                        const table = object_val.Object.toTable();

                        if (index >= table.elements.items.len) {
                            std.debug.print("Runtime Error: Array index out of bounds.\n", .{});
                            return error.RuntimeError;
                        }
                        self.push(table.elements.items[index]);
                    } else if (object_val == .Object and object_val.Object.obj_type == .String) {
                        const string = object_val.Object.toString();

                        if (index >= string.chars.len) {
                            std.debug.print("Runtime Error: String index out of bounds.\n", .{});
                            return error.RuntimeError;
                        }

                        const char = string.chars[index];

                        var char_slice = try self.allocator.alloc(u8, 1);
                        char_slice[0] = char;

                        var new_str = try self.createString(char_slice);

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
                    const name_str_obj = name_val.Object.toString();
                    const name_str = name_str_obj.chars;

                    if (std.mem.eql(u8, name_str, "_")) {
                        self.push(.{ .Boolean = true });
                        continue;
                    }

                    if (target != .Object or target.Object.obj_type != .Variant) {
                        self.push(.{ .Boolean = false });
                        continue;
                    }

                    const variant_obj = target.Object.toVariant();
                    if (!std.mem.eql(u8, variant_obj.variant_name.chars, name_str)) {
                        self.push(.{ .Boolean = false });
                        continue;
                    }

                    if (has_ns == 1) {
                        const ns_val = frame.function.chunk.constants.items[ns_idx];
                        const ns_str_obj = ns_val.Object.toString();
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
                        const variant_obj = target.Object.toVariant();

                        for (variant_obj.payload) |val| {
                            self.push(val);
                        }
                    }
                },
                .OP_BUILD_VARIANT => {
                    const ns_val = self.readConstant();
                    const name_val = self.readConstant();
                    const arg_count = self.readByte();

                    const ns_obj = ns_val.Object.toString();
                    const name_obj = name_val.Object.toString();

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
