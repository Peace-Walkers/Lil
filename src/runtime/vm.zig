const std = @import("std");
const chunk_mod = @import("../compiler/chunk.zig");
const OpCode = chunk_mod.OpCode;
const Chunk = chunk_mod.Chunk;
const value_mod = @import("../compiler/value.zig");
const Value = value_mod.Value;
const StringObj = value_mod.StringObj;
const FunctionObj = value_mod.FunctionObj;
const TableObj = value_mod.TableObj;
const MapObj = value_mod.MapObj;
const VariantObj = value_mod.VariantObj;
const NativeObj = value_mod.NativeObj;
const NativeFn = value_mod.NativeFn;
const ObjType = value_mod.ObjType;
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

pub const ResolvedModule = struct {
    source: []const u8,
    file_path: []const u8,
};

pub const ResolveFn = *const fn (vm: *VM, module_name: []const u8, caller_path: []const u8) anyerror!ResolvedModule;

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
    map_methods: std.StringHashMap(NativeFn),
    result_methods: std.StringHashMap(NativeFn),

    import_resolver: ?ResolveFn,
    loaded_modules: std.StringHashMap(Value),
    module_stack: [64][]const u8 = undefined,
    module_depth: usize = 0,

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
            .map_methods = std.StringHashMap(NativeFn).init(allocator),
            .halt_frame_count = null,
            .io = io,
            .loaded_modules = std.StringHashMap(Value).init(allocator),
            .import_resolver = null,
        };

        try vm.table_methods.put("push", stdlib.methods.table.push);
        try vm.table_methods.put("map", stdlib.methods.table.map);
        try vm.table_methods.put("filter", stdlib.methods.table.filter);
        try vm.table_methods.put("len", stdlib.methods.table.len);
        try vm.table_methods.put("pop", stdlib.methods.table.pop);

        try vm.string_methods.put("push", stdlib.methods.string.push);
        try vm.string_methods.put("len", stdlib.methods.string.len);
        try vm.string_methods.put("split", stdlib.methods.string.split);

        try vm.map_methods.put("put", stdlib.methods.map.put);
        try vm.map_methods.put("get", stdlib.methods.map.get);

        try vm.result_methods.put("unwrap", stdlib.methods.variant.unwrap);

        return vm;
    }

    pub fn eval(self: *Self, source: []const u8) !void {
        const lexer = @import("../compiler/lexer.zig");
        const parser = @import("../compiler/parser.zig");
        const compiler = @import("../compiler/compiler.zig");
        const diagnostics = @import("../compiler/diagnostic.zig");

        var frontend_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const frontend_alloc = frontend_arena.allocator();
        var err_accumulator = diagnostics.ErrorAccumulator.init(frontend_alloc);

        var scanner = lexer.Lexer.init(source);
        var p = parser.Parser.init(&scanner, self.allocator, err_accumulator.reporter());
        const ast_root = p.parse() catch {
            std.debug.print("Fatal Parsing Error.\n”", .{});
            return error.CompileError;
        };

        if (err_accumulator.has_error) {
            err_accumulator.printErrors();

            frontend_arena.deinit();
            return error.CompileError;
        }

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

        frontend_arena.deinit();

        try self.interpret(script_function);
    }

    pub fn setGlobal(self: *Self, name: []const u8, value: Value) !void {
        try self.globals.put(name, value);
    }

    pub fn createNative(self: *Self, comptime name: []const u8, func: NativeFn) !Value {
        const native_obj = try self.allocator.create(NativeObj);
        native_obj.* = .{
            .obj = .{ .obj_type = .Native, .next = null },
            .function = func,
            .name = name,
        };
        return .{ .Object = &native_obj.obj };
    }

    pub fn bindNative(self: *Self, table: *TableObj, comptime name: []const u8, func: NativeFn) !void {
        const native_val = try self.createNative(name, func);
        try table.fields.put(name, native_val);
    }

    pub fn evalModule(self: *Self, source: []const u8) !Value {
        const lexer = @import("../compiler/lexer.zig");
        const parser = @import("../compiler/parser.zig");
        const compiler = @import("../compiler/compiler.zig");
        const diagnostics = @import("../compiler/diagnostic.zig");

        var scanner = lexer.Lexer.init(source);
        var err_accumulator = diagnostics.ErrorAccumulator.init(self.allocator);
        var p = parser.Parser.init(&scanner, self.allocator, err_accumulator.reporter());
        const ast_root = try p.parse();

        if (err_accumulator.has_error) {
            err_accumulator.printErrors();
            return error.CompileError;
        }

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

    pub fn createString(self: *Self, chars: []const u8) !*StringObj {
        const obj_str = try self.allocator.create(StringObj);
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

    pub fn createMap(self: *Self) !*MapObj {
        const map_obj = try self.allocator.create(MapObj);
        map_obj.* = .{
            .obj = .{ .obj_type = .Map, .next = null },
            .hashmap = std.HashMap(Value, Value, value_mod.ValueContext, 80).init(self.allocator),
        };
        return map_obj;
    }

    pub fn createVariant(self: *Self, namespace: *StringObj, name: *StringObj, payload: []Value) !*VariantObj {
        const variant_obj = try self.allocator.create(VariantObj);
        variant_obj.* = .{
            .obj = .{ .obj_type = .Variant, .next = null },
            .namespace = namespace,
            .variant_name = name,
            .payload = payload,
        };
        return variant_obj;
    }

    pub fn createSystem(self: *Self, kind: value_mod.SystemType, ptr: *anyopaque) !*value_mod.SystemObj {
        const sys_obj = try self.allocator.create(value_mod.SystemObj);
        sys_obj.* = .{
            .obj = .{ .obj_type = .System, .next = null },
            .kind = kind,
            .ptr = ptr,
            .methods = std.StringHashMap(Value).init(self.allocator),
        };
        return sys_obj;
    }

    pub fn createResultOk(self: *Self, payload: Value) !Value {
        const result = try self.allocator.dupe(u8, "Result");
        const ok = try self.allocator.dupe(u8, "Ok");
        const ns_str = try self.createString(result);
        const name_str = try self.createString(ok);

        const payload_slice = try self.allocator.alloc(Value, 1);
        payload_slice[0] = payload;

        const variant_obj = try self.createVariant(ns_str, name_str, payload_slice);
        return .{ .Object = &variant_obj.obj };
    }

    pub fn createResultErr(self: *Self, error_msg: []const u8) !Value {
        const result = try self.allocator.dupe(u8, "Result");
        const err = try self.allocator.dupe(u8, "Err");
        const ns_str = try self.createString(result);
        const name_str = try self.createString(err);
        const err_str = try self.createString(error_msg);

        const payload_slice = try self.allocator.alloc(Value, 1);

        payload_slice[0] = .{ .Object = &err_str.obj };
        const variant_obj = try self.createVariant(ns_str, name_str, payload_slice);
        return .{ .Object = &variant_obj.obj };
    }

    /// Search in Table.fields specific key and check it type
    pub fn expectField(self: *Self, table: *TableObj, name: []const u8, expected_type: ObjType) !Value {
        const value = table.fields.get(name) orelse return self.createResultErr(try std.fmt.allocPrint(self.allocator, "Missing expected key '{s}' table.", .{name}));

        if (value != .Object) {
            return self.createResultErr(try std.fmt.allocPrint(self.allocator, "Key '{s}' must be an object of type {s} but found {s}", .{ name, @tagName(expected_type), @tagName(value) }));
        }

        if (value.Object.obj_type != expected_type) {
            return self.createResultErr(try std.fmt.allocPrint(self.allocator, "Key '{s}' must be a {s} but found {s}", .{ name, @tagName(expected_type), @tagName(value.Object.obj_type) }));
        }

        return value;
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
            if (a == .Null or b == .Null)
                return false;
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
                    .Map => {
                        const map_a = a_obj.toMap();
                        const map_b = b_obj.toMap();

                        return map_a == map_b;
                    },
                    .System => {
                        const system_a = a_obj.toSystem();
                        const system_b = b_obj.toSystem();

                        if (system_a.kind != system_b.kind)
                            return false;

                        if (system_a.ptr != system_b.ptr)
                            return false;

                        return true;
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

    pub fn panic(self: *Self, comptime format: []const u8, args: anytype) void {
        std.debug.print("\n[Runtime Error] ", .{});
        std.debug.print(format, args);
        std.debug.print("\n", .{});

        std.debug.print("Stack trace:\n", .{});

        var i: usize = self.frame_count;
        while (i > 0) {
            i -= 1;
            const frame = &self.frames[i];
            const function = frame.function;

            const instruction_idx = if (frame.ip > 0) frame.ip - 1 else 0;

            const line = if (function.chunk.lines.items.len > instruction_idx)
                function.chunk.lines.items[instruction_idx]
            else
                0;

            const function_name = if (function.name) |n| n.chars else "<main>";

            std.debug.print("  at {s}() line {d}\n", .{ function_name, line });
        }

        const current_module = if (self.module_depth > 0)
            self.module_stack[self.module_depth - 1]
        else
            "unknown";

        std.debug.print("  in module: {s}\n\n", .{current_module});
    }

    pub fn interpret(self: *Self, function: *FunctionObj) anyerror!void {
        self.push(.{ .Object = &function.obj });

        const frame_idx = self.frame_count;

        self.frames[frame_idx] = .{
            .function = function,
            .ip = 0,
            .slot_offset = self.stack_top - 1,
        };
        self.frame_count += 1;

        const prev_halt = self.halt_frame_count;
        self.halt_frame_count = frame_idx;
        try self.run();

        self.halt_frame_count = prev_halt;
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
                    constant.retain();
                    self.push(constant);
                },
                .OP_DEFINE_GLOBAL => {
                    const name_val = self.readConstant();
                    const name_obj = name_val.Object.toString();
                    const name = name_obj.chars;

                    const value = self.pop();
                    if (self.globals.get(name)) |old_val| {
                        old_val.release(self.allocator, self.io.system);
                    }
                    try self.globals.put(name, value);
                },
                .OP_SET_GLOBAL => {
                    const name_val = self.readConstant();
                    const name_obj = name_val.Object.toString();
                    const name = name_obj.chars;

                    if (self.globals.get(name)) |old_val| {
                        old_val.release(self.allocator, self.io.system);
                    } else {
                        std.debug.print("Error undefined variable: '{s}'.\n", .{name});
                        return error.RuntimeError;
                    }

                    const value = self.peek(0);
                    value.retain();
                    try self.globals.put(name, value);
                },
                .OP_GET_GLOBAL => {
                    const name_val = self.readConstant();
                    const name_obj = name_val.Object.toString();
                    const name = name_obj.chars;

                    if (self.globals.get(name)) |value| {
                        value.retain();
                        self.push(value);
                    } else {
                        self.panic("Undefined variable '{s}'\n", .{name});
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
                .OP_BUILD_MAP => {
                    const map_len = self.readByte();

                    const map_object = try self.createMap();
                    var i: usize = 0;

                    while (i < map_len) : (i += 1) {
                        const value = self.pop();
                        const key = self.pop();

                        try map_object.hashmap.put(key, value);
                    }

                    self.push(.{ .Object = &map_object.obj });
                },
                .OP_IMPORT => {
                    const path_val = self.pop();
                    defer path_val.release(self.allocator, self.io.system);
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

                    const current_path = if (self.module_depth > 0)
                        self.module_stack[self.module_depth - 1]
                    else
                        ".";

                    const resolved = self.import_resolver.?(self, module_name, current_path) catch {
                        std.debug.print("Runtime Error: Failed to load module '{s}'.\n", .{module_name});
                        return error.RuntimeError;
                    };

                    self.module_stack[self.module_depth] = resolved.file_path;
                    self.module_depth += 1;

                    const module_val = self.evalModule(resolved.source) catch |err| {
                        self.module_depth -= 1;
                        return err;
                    };

                    self.module_depth -= 1;

                    try self.loaded_modules.put(module_name, module_val);
                    self.push(module_val);
                },
                .OP_GET_PROPERTY => {
                    const name_val = self.readConstant();
                    const name_obj = name_val.Object.toString();
                    const property_name = name_obj.chars;

                    const instance_val = self.pop();

                    if (instance_val != .Object or (instance_val.Object.obj_type != .Table and instance_val.Object.obj_type != .System)) {
                        std.log.info("obj_type: {s}", .{@tagName(instance_val.Object.obj_type)});
                        std.debug.print("Runtime Error: Only tables have properties.\n", .{});
                        return error.RuntimeError;
                    }

                    switch (instance_val.Object.obj_type) {
                        .Table => {
                            const table = instance_val.Object.toTable();

                            if (table.fields.get(property_name)) |value| {
                                value.retain();
                                self.push(value);
                            } else {
                                std.debug.print("Runtime Error: Undefined property '{s}'.\n", .{property_name});
                                return error.RuntimeError;
                            }
                        },
                        .System => {
                            const sys_obj = instance_val.Object.toSystem();

                            if (sys_obj.methods.get(property_name)) |method| {
                                method.retain();
                                self.push(method);
                            } else {
                                self.panic("System object has no property or method named '{s}'", .{property_name});
                                return error.RuntimeError;
                            }
                        },
                        else => unreachable,
                    }
                    instance_val.release(self.allocator, self.io.system);
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

                    if (table.fields.get(property_name)) |old_val| {
                        old_val.release(self.allocator, self.io.system);
                    }

                    try table.fields.put(property_name, value);

                    value.retain();
                    self.push(value);
                    instance_val.release(self.allocator, self.io.system);
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

                                const result = native_func(@ptrCast(self), total_args, args_slice.ptr) catch |err| {
                                    self.panic("{s}", .{@errorName(err)});
                                    return error.RuntimeError;
                                };

                                var i: usize = 0;
                                while (i < total_args) : (i += 1) {
                                    self.stack[self.stack_top - 1 - i].release(self.allocator, self.io.system);
                                }

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

                                const result = native_func(@ptrCast(self), total_args, args_slice.ptr) catch |err| {
                                    self.panic("{s}", .{@errorName(err)});
                                    return error.RuntimeError;
                                };

                                var i: usize = 0;
                                while (i < total_args) : (i += 1) {
                                    self.stack[self.stack_top - 1 - i].release(self.allocator, self.io.system);
                                }
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
                                        const result = native_fn(@ptrCast(self), total_args, args_slice.ptr) catch |err| {
                                            self.panic("{s}", .{@errorName(err)});
                                            return error.RuntimeError;
                                        };
                                        var i: usize = 0;
                                        while (i < total_args) : (i += 1) {
                                            self.stack[self.stack_top - 1 - i].release(self.allocator, self.io.system);
                                        }
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
                        .Map => {
                            if (self.map_methods.get(method_name)) |native_fn| {
                                const total_args = arg_count + 1;
                                const args_slice = self.stack[self.stack_top - total_args .. self.stack_top];
                                const result = native_fn(@ptrCast(self), total_args, args_slice.ptr) catch |err| {
                                    self.panic("{s}", .{@errorName(err)});
                                    return error.RuntimeError;
                                };
                                var i: usize = 0;
                                while (i < total_args) : (i += 1) {
                                    self.stack[self.stack_top - 1 - i].release(self.allocator, self.io.system);
                                }
                                self.stack_top -= total_args;
                                self.push(result);
                            } else {
                                std.debug.print("Runtime Error: Undefined Map method '{s}'.\n", .{method_name});
                                return error.RuntimeError;
                            }
                        },
                        .System => {
                            const sys_obj = receiver.Object.toSystem();

                            if (sys_obj.methods.get(method_name)) |method| {
                                if (method != .Object or method.Object.obj_type != .Native) {
                                    self.panic("Runtime Error: Property '{s}' is not a native function.\n", .{method_name});
                                    return error.RuntimeError;
                                }
                                const native_fn = method.Object.toNative().function;

                                const total_args = arg_count + 1;
                                const args_slice = self.stack[self.stack_top - total_args .. self.stack_top];

                                const result = native_fn(@ptrCast(self), total_args, args_slice.ptr) catch |err| {
                                    self.panic("{s}", .{@errorName(err)});
                                    return error.RuntimeError;
                                };
                                var i: usize = 0;
                                while (i < total_args) : (i += 1) {
                                    self.stack[self.stack_top - 1 - i].release(self.allocator, self.io.system);
                                }
                                self.stack_top -= total_args;
                                self.push(result);
                            } else {
                                self.panic("System object has no property or method named '{s}'", .{method_name});
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
                        self.panic("Operand must be numbers, got '{s}' and '{s}'.", .{ @tagName(a), @tagName(b) });
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
                    a.release(self.allocator, self.io.system);
                    b.release(self.allocator, self.io.system);
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

                    var i: usize = current_frame.slot_offset;
                    while (i < self.stack_top) : (i += 1) {
                        self.stack[i].release(self.allocator, self.io.system);
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
                    const val = self.pop();
                    val.release(self.allocator, self.io.system);
                },
                .OP_GET_LOCAL => {
                    const slot = self.readByte();
                    const val = self.stack[frame.slot_offset + slot];
                    val.retain();
                    self.push(val);
                },
                .OP_SET_LOCAL => {
                    const slot = self.readByte();
                    const new_value = self.peek(0);
                    new_value.retain();
                    self.stack[frame.slot_offset + slot].release(self.allocator, self.io.system);
                    self.stack[frame.slot_offset + slot] = new_value;
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
                                self.panic("Expected {d} arguments but got {d}.", .{ func.arity, arg_count });
                                return error.RuntimeError;
                            }

                            if (self.frame_count == 64) {
                                self.panic("Stack Overflow\n", .{});
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
                            const result = native_obj.function(self, arg_count, args_slice.ptr) catch |err| {
                                self.panic("{s}", .{@errorName(err)});
                                return error.RuntimeError;
                            };

                            var i: usize = 0;
                            while (i < arg_count + 1) : (i += 1)
                                self.stack[self.stack_top - 1 - i].release(self.allocator, self.io.system);

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
                        const popped_variant = self.pop();
                        const payload_val = variant.payload[0];
                        payload_val.retain();
                        self.push(payload_val);
                        popped_variant.release(self.allocator, self.io.system);
                    } else {
                        if (self.frame_count == 1) {
                            //INFO: main script case
                            const msg = variant.payload[0].Object.toString().chars;
                            std.debug.print("Unhandled error in main : {s}\n", .{msg});
                            return error.RuntimeError;
                        } else {
                            //INFO: inside a function case
                            const err_result = self.pop();
                            const current_frame = self.frames[self.frame_count - 1];

                            var i: usize = current_frame.slot_offset;
                            while (i < self.stack_top) : (i += 1) {
                                self.stack[i].release(self.allocator, self.io.system);
                            }

                            self.frame_count -= 1;
                            self.stack_top = current_frame.slot_offset;
                            self.push(err_result);
                        }
                    }
                },
                .OP_GET_INDEX => {
                    const index_val = self.pop();
                    const object_val = self.pop();

                    if (object_val != .Object) {
                        self.panic("Cannot index a non-object type: {s}.", .{@tagName(object_val)});
                        return error.RuntimeError;
                    }

                    switch (object_val.Object.obj_type) {
                        .Map => {
                            const map = object_val.Object.toMap();
                            if (map.hashmap.get(index_val)) |v| {
                                v.retain();
                                self.push(v);
                            } else {
                                self.panic("Unknown key in Map.", .{});
                                return error.RuntimeError;
                            }
                        },
                        .Table => {
                            if (index_val != .Number) {
                                self.panic("Array index must be a number, found {s}.", .{@tagName(index_val)});
                                return error.RuntimeError;
                            }
                            const index: usize = @intCast(index_val.Number);
                            const table = object_val.Object.toTable();

                            if (index >= table.elements.items.len) {
                                self.panic("Array index out of bounds: length is {d} but index is {d}.", .{ table.elements.items.len, index });
                                return error.RuntimeError;
                            }
                            table.elements.items[index].retain();
                            self.push(table.elements.items[index]);
                        },
                        .String => {
                            if (index_val != .Number) {
                                self.panic("String index must be a number.", .{});
                                return error.RuntimeError;
                            }
                            const index: usize = @intCast(index_val.Number);
                            const string = object_val.Object.toString();

                            if (index >= string.chars.len) {
                                self.panic("String index out of bounds.", .{});
                                return error.RuntimeError;
                            }

                            const char = string.chars[index];
                            var char_slice = try self.allocator.alloc(u8, 1);
                            char_slice[0] = char;
                            var new_str = try self.createString(char_slice);

                            self.push(.{ .Object = &new_str.obj });
                        },
                        else => {
                            self.panic("Can only index Arrays, Strings and Maps (found {s}).", .{@tagName(object_val.Object.obj_type)});
                            return error.RuntimeError;
                        },
                    }
                    index_val.release(self.allocator, self.io.system);
                    object_val.release(self.allocator, self.io.system);
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
                            val.retain();
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
