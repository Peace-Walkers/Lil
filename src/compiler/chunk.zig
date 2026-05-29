const std = @import("std");
const Value = @import("value.zig").Value;

pub const OpCode = enum(u8) {
    OP_CONSTANT,
    OP_POP,

    OP_DEFINE_GLOBAL,
    OP_GET_GLOBAL,
    OP_SET_GLOBAL,
    OP_GET_LOCAL,
    OP_SET_LOCAL,

    OP_GET_PROPERTY,
    OP_INVOKE,

    OP_GET_INDEX,

    OP_ADD,
    OP_SUBTRACT,
    OP_MULTIPLY,
    OP_DIVIDE,

    OP_TRUE,
    OP_FALSE,
    OP_EQUAL,
    OP_GREATER,
    OP_LESS,

    OP_CALL,
    OP_JUMP,
    OP_JUMP_IF_FALSE,
    OP_LOOP,

    OP_BUILD_TABLE,

    OP_RETURN,
};

pub const Chunk = struct {
    const Self = @This();

    code: std.ArrayList(u8),
    constants: std.ArrayList(Value),
    lines: std.ArrayList(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .code = .empty,
            .constants = .empty,
            .lines = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.code.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.lines.deinit(self.allocator);
    }

    pub fn write(self: *Self, byte: u8, line: usize) !void {
        try self.code.append(self.allocator, byte);
        try self.lines.append(self.allocator, line);
    }

    pub fn addConstant(self: *Self, value: Value) !u8 {
        try self.constants.append(self.allocator, value);
        return @intCast(self.constants.items.len - 1);
    }
};
