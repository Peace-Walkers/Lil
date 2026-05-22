const std = @import("std");
const chunk_mod = @import("../compiler/chunk.zig");
const OpCode = chunk_mod.OpCode;
const Chunk = chunk_mod.Chunk;
const value_mod = @import("../compiler/value.zig");
const Value = value_mod.Value;
const ObjString = value_mod.ObjString;

pub const VmError = error{
    CompileError,
    RuntimeError,
};

pub const VM = struct {
    const Self = @This();

    chunk: *Chunk,
    ip: usize, // instruction pointer

    stack: [256]Value,
    stack_top: usize,

    globals: std.StringHashMap(Value),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .chunk = undefined,
            .ip = 0,
            .stack = undefined,
            .stack_top = 0,
            .globals = std.StringHashMap(Value).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.globals.deinit();
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
        const byte = self.chunk.code.items[self.ip];
        self.ip += 1;
        return byte;
    }

    fn reasConstant(self: *Self) Value {
        return self.chunk.constants.items[self.readByte()];
    }

    pub fn interpret(self: *Self, chunk: *Chunk) !void {
        self.chunk = chunk;
        self.ip = 0;
        return self.run();
    }

    fn run(self: *Self) !void {
        while (true) {
            const instruction = self.readByte();
            const op: OpCode = @enumFromInt(instruction);

            switch (op) {
                .OP_CONSTANT => {
                    const constant = self.reasConstant();
                    self.push(constant);
                },
                .OP_DEFINE_GLOBAL => {
                    const name_val = self.reasConstant();
                    const name_obj: *ObjString = @fieldParentPtr("obj", name_val.Object);
                    const name = name_obj.chars;

                    const value = self.pop();
                    try self.globals.put(name, value);
                },
                .OP_GET_GLOBAL => {
                    const name_val = self.reasConstant();
                    const name_obj: *ObjString = @fieldParentPtr("obj", name_val.Object);
                    const name = name_obj.chars;

                    if (self.globals.get(name)) |value| {
                        self.push(value);
                    } else {
                        std.debug.print("Runtime Error: undefined var: {s}\n", .{name});
                        return error.RuntimeError;
                    }
                },
                .OP_ADD => {
                    const b = self.pop();
                    const a = self.pop();

                    const result = a.Number + b.Number;
                    self.push(.{ .Number = result });
                },
                .OP_RETURN => {
                    std.debug.print("====FINAL MEMORY STATE====\n", .{});
                    var it = self.globals.iterator();
                    while (it.next()) |entry| {
                        std.debug.print("{s} = ", .{entry.key_ptr.*});
                        entry.value_ptr.*.print();
                        std.debug.print("\n", .{});
                    }
                    return;
                },
                else => {
                    std.debug.print("Error: Invalid OpCode.\n", .{});
                    return error.RuntimeError;
                },
            }
        }
    }
};
